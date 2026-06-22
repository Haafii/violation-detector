/// Track lifecycle states used by ByteTracker.
enum TrackState { tentative, confirmed, lost, removed }

/// A single tracked object managed by the ByteTracker.
class Track {
  Track({
    required this.trackId,
    required this.bbox, // [x1, y1, x2, y2]
    required this.score,
    required this.classId,
    required this.className,
    required this.kalman,
  });

  final int trackId;
  List<double> bbox;
  double score;
  int classId;
  String className;
  final KalmanBoxTracker kalman;

  TrackState state = TrackState.tentative;

  /// Consecutive frames with a matched detection.
  int hitStreak = 1;

  /// Frames since last matched detection.
  int timeSinceUpdate = 0;

  /// Age in frames (total frames this track has existed).
  int frameCount = 1;

  bool get isConfirmed => state == TrackState.confirmed;
  bool get isLost => state == TrackState.lost;
  bool get isRemoved => state == TrackState.removed;

  /// Predict next position via Kalman and increment age.
  void predict() {
    kalman.predict();
    timeSinceUpdate++;
    frameCount++;
  }

  /// Update track with a matched detection.
  void update(List<double> newBbox, double newScore) {
    kalman.update(newBbox);
    bbox = kalman.toBbox();
    score = newScore;
    timeSinceUpdate = 0;
    hitStreak++;
  }

  /// Mark as lost (no match this frame).
  void markLost() {
    state = TrackState.lost;
    hitStreak = 0;
  }

  /// Mark for removal.
  void markRemoved() => state = TrackState.removed;
}

// ---------------------------------------------------------------------------
// Inline KalmanBoxTracker to avoid import cycles — placed here for locality.
// Full implementation is in kalman_box_tracker.dart.
// ---------------------------------------------------------------------------

/// 8-dimensional constant-velocity Kalman filter for bounding boxes.
///
/// State vector: [cx, cy, a, h, vx, vy, va, vh]
///   cx, cy — box centre x/y
///   a       — aspect ratio (w / h)
///   h       — box height
///   vx, vy, va, vh — corresponding velocities
class KalmanBoxTracker {
  static int _idCounter = 0;
  static void resetIdCounter() => _idCounter = 0;

  KalmanBoxTracker(List<double> bbox) : trackId = ++_idCounter {
    _initState(bbox);
  }

  final int trackId;

  // State: [cx, cy, a, h, vx, vy, va, vh]
  late List<double> _x;

  // Covariance P (8×8, stored as flat 64-element list row-major)
  late List<double> _P;

  // Process noise Q (diagonal)
  static final List<double> _Q = _diagFlat([
    1.0, 1.0, 1e-4, 1e-2, // position noise
    1e-2, 1e-2, 1e-6, 1e-4, // velocity noise
  ]);

  // Measurement noise R (4×4 diagonal)
  static final List<double> _R = _diagFlat([10.0, 10.0, 1e-3, 1.0]);

  // Observation matrix H (4×8): extracts [cx, cy, a, h] from state
  static final List<double> _H = _buildH();

  // Transition matrix F (8×8): constant-velocity model
  static final List<double> _F = _buildF();

  void _initState(List<double> bbox) {
    _x = _bboxToZ(bbox);
    _x.addAll([0.0, 0.0, 0.0, 0.0]); // initial velocities = 0

    // Initial covariance — high uncertainty on velocities
    _P = _diagFlat([
      10.0, 10.0, 10.0, 10.0, // position
      1e4, 1e4, 1e4, 1e4, // velocity — very uncertain initially
    ]);
  }

  /// Convert bbox [x1,y1,x2,y2] → measurement [cx,cy,a,h]
  static List<double> _bboxToZ(List<double> b) {
    final w = b[2] - b[0];
    final h = b[3] - b[1];
    return [b[0] + w / 2, b[1] + h / 2, w / h, h];
  }

  /// Convert state [cx,cy,a,h,...] → bbox [x1,y1,x2,y2]
  List<double> toBbox() {
    final cx = _x[0];
    final cy = _x[1];
    final a = _x[2].abs().clamp(1e-4, 1e6);
    final h = _x[3].abs().clamp(1.0, 1e6);
    final w = a * h;
    return [cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2];
  }

  /// Predict — advance state by one time step.
  void predict() {
    _x = _matVec(_F, _x, 8, 8);
    _P = _matAdd(_matMul(_matMul(_F, _P, 8, 8), _transpose(_F, 8, 8), 8, 8), _Q, 8, 8);
  }

  /// Update — correct state with new measurement (bbox).
  void update(List<double> bbox) {
    final z = _bboxToZ(bbox); // (4,)

    // Innovation: y = z - H*x
    final Hx = _matVec(_H, _x, 4, 8);
    final y = List<double>.generate(4, (i) => z[i] - Hx[i]);

    // S = H*P*H' + R
    final HP = _matMul(_H, _P, 4, 8);
    final HPHt = _matMul(HP, _transpose(_H, 4, 8), 4, 4);
    final S = _matAdd(HPHt, _R, 4, 4);

    // K = P*H' * inv(S)
    final PHt = _matMul(_P, _transpose(_H, 4, 8), 8, 4);
    final Sinv = _inv4(S);
    final K = _matMul(PHt, Sinv, 8, 4);

    // x = x + K*y
    final Ky = _matVec(K, y, 8, 4);
    for (int i = 0; i < 8; i++) {
      _x[i] += Ky[i];
    }

    // P = (I - K*H) * P
    final KH = _matMul(K, _H, 8, 8);
    final IKH = List<double>.generate(64, (idx) {
      final r = idx ~/ 8;
      final c = idx % 8;
      return (r == c ? 1.0 : 0.0) - KH[idx];
    });
    _P = _matMul(IKH, _P, 8, 8);
  }

  // ── Matrix helpers ─────────────────────────────────────────────────────────

  static List<double> _buildF() {
    // 8×8 identity + dt=1 on velocity block
    final f = List<double>.filled(64, 0.0);
    for (int i = 0; i < 8; i++) {
      f[i * 8 + i] = 1.0;
    }
    // position += velocity
    f[0 * 8 + 4] = 1.0; // cx += vx
    f[1 * 8 + 5] = 1.0; // cy += vy
    f[2 * 8 + 6] = 1.0; // a  += va
    f[3 * 8 + 7] = 1.0; // h  += vh
    return f;
  }

  static List<double> _buildH() {
    // 4×8: rows select cx,cy,a,h from state
    final h = List<double>.filled(32, 0.0);
    h[0 * 8 + 0] = 1.0;
    h[1 * 8 + 1] = 1.0;
    h[2 * 8 + 2] = 1.0;
    h[3 * 8 + 3] = 1.0;
    return h;
  }

  static List<double> _diagFlat(List<double> d) {
    final n = d.length;
    final m = List<double>.filled(n * n, 0.0);
    for (int i = 0; i < n; i++) {
      m[i * n + i] = d[i];
    }
    return m;
  }

  /// Multiply (rows×cols) matrix A by vector x of length cols → vector of length rows.
  static List<double> _matVec(List<double> A, List<double> x, int rows, int cols) {
    final out = List<double>.filled(rows, 0.0);
    for (int r = 0; r < rows; r++) {
      double s = 0.0;
      for (int c = 0; c < cols; c++) {
        s += A[r * cols + c] * x[c];
      }
      out[r] = s;
    }
    return out;
  }

  /// Multiply (m×k) × (k×n) → (m×n).
  static List<double> _matMul(List<double> A, List<double> B, int m, int n) {
    final k = A.length ~/ m;
    final out = List<double>.filled(m * n, 0.0);
    for (int r = 0; r < m; r++) {
      for (int c = 0; c < n; c++) {
        double s = 0.0;
        for (int i = 0; i < k; i++) {
          s += A[r * k + i] * B[i * n + c];
        }
        out[r * n + c] = s;
      }
    }
    return out;
  }

  static List<double> _matAdd(List<double> A, List<double> B, int m, int n) =>
      List<double>.generate(m * n, (i) => A[i] + B[i]);

  /// Transpose (rows×cols) → (cols×rows).
  static List<double> _transpose(List<double> A, int rows, int cols) {
    final out = List<double>.filled(rows * cols, 0.0);
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        out[c * rows + r] = A[r * cols + c];
      }
    }
    return out;
  }

  /// Invert a 4×4 matrix (used for S inversion).
  static List<double> _inv4(List<double> m) {
    // Use Gauss-Jordan elimination on augmented [m | I]
    final a = List<double>.from(m); // 4×4 → 16 elements
    final inv = List<double>.generate(16, (i) => (i ~/ 4 == i % 4) ? 1.0 : 0.0);

    for (int col = 0; col < 4; col++) {
      // Find pivot
      int pivot = col;
      double maxVal = a[col * 4 + col].abs();
      for (int row = col + 1; row < 4; row++) {
        if (a[row * 4 + col].abs() > maxVal) {
          maxVal = a[row * 4 + col].abs();
          pivot = row;
        }
      }
      // Swap rows
      if (pivot != col) {
        for (int k = 0; k < 4; k++) {
          double tmp = a[col * 4 + k];
          a[col * 4 + k] = a[pivot * 4 + k];
          a[pivot * 4 + k] = tmp;
          tmp = inv[col * 4 + k];
          inv[col * 4 + k] = inv[pivot * 4 + k];
          inv[pivot * 4 + k] = tmp;
        }
      }
      // Scale pivot row
      final divisor = a[col * 4 + col];
      if (divisor.abs() < 1e-12) continue; // singular — skip
      for (int k = 0; k < 4; k++) {
        a[col * 4 + k] /= divisor;
        inv[col * 4 + k] /= divisor;
      }
      // Eliminate column
      for (int row = 0; row < 4; row++) {
        if (row == col) continue;
        final factor = a[row * 4 + col];
        for (int k = 0; k < 4; k++) {
          a[row * 4 + k] -= factor * a[col * 4 + k];
          inv[row * 4 + k] -= factor * inv[col * 4 + k];
        }
      }
    }
    return inv;
  }
}
