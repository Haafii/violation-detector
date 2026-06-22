/// Pure Dart O(n³) Hungarian algorithm (Kuhn-Munkres).
///
/// Solves the linear assignment problem: given a cost matrix of size m×n,
/// finds the assignment of rows to columns that minimises total cost.
///
/// Returns a list of length m where result[row] = assigned column, or -1
/// if that row is unassigned (when m > n).
List<int> hungarianAlgorithm(List<List<double>> costMatrix) {
  if (costMatrix.isEmpty) return [];
  final m = costMatrix.length;
  final n = costMatrix[0].length;

  // Pad to square if needed
  final size = m > n ? m : n;
  final cost = List.generate(size, (r) {
    return List<double>.generate(size, (c) {
      if (r < m && c < n) return costMatrix[r][c];
      return 0.0;
    });
  });

  // u[i] = label for row i, v[j] = label for col j
  final u = List<double>.filled(size + 1, 0.0);
  final v = List<double>.filled(size + 1, 0.0);
  // p[j] = row matched to col j (1-indexed), 0 = unmatched
  final p = List<int>.filled(size + 1, 0);
  // way[j] = previous col in augmenting path
  final way = List<int>.filled(size + 1, 0);

  for (int i = 1; i <= size; i++) {
    p[0] = i;
    int j0 = 0;
    final minVal = List<double>.filled(size + 1, double.infinity);
    final used = List<bool>.filled(size + 1, false);

    do {
      used[j0] = true;
      final i0 = p[j0];
      double delta = double.infinity;
      int j1 = -1;

      for (int j = 1; j <= size; j++) {
        if (!used[j]) {
          final cur = cost[i0 - 1][j - 1] - u[i0] - v[j];
          if (cur < minVal[j]) {
            minVal[j] = cur;
            way[j] = j0;
          }
          if (minVal[j] < delta) {
            delta = minVal[j];
            j1 = j;
          }
        }
      }

      for (int j = 0; j <= size; j++) {
        if (used[j]) {
          u[p[j]] += delta;
          v[j] -= delta;
        } else {
          minVal[j] -= delta;
        }
      }

      if (j1 >= 0) j0 = j1;
    } while (p[j0] != 0);

    do {
      p[j0] = p[way[j0]];
      j0 = way[j0];
    } while (j0 != 0);
  }

  // Decode: build row→col assignment
  final assignment = List<int>.filled(m, -1);
  for (int j = 1; j <= size; j++) {
    final row = p[j] - 1;
    final col = j - 1;
    if (row >= 0 && row < m && col < n) {
      assignment[row] = col;
    }
  }
  return assignment;
}

/// Build a cost matrix from IoU values between boxes.
///
/// cost[i][j] = 1 - IoU(tracksBoxes[i], detBoxes[j])
/// so the Hungarian algorithm minimises 1-IoU (= maximises IoU).
List<List<double>> iouCostMatrix(
  List<List<double>> trackBoxes,
  List<List<double>> detBoxes,
) {
  return List.generate(trackBoxes.length, (i) {
    return List<double>.generate(detBoxes.length, (j) {
      return 1.0 - _iou(trackBoxes[i], detBoxes[j]);
    });
  });
}

double _iou(List<double> a, List<double> b) {
  final x1 = a[0] > b[0] ? a[0] : b[0];
  final y1 = a[1] > b[1] ? a[1] : b[1];
  final x2 = a[2] < b[2] ? a[2] : b[2];
  final y2 = a[3] < b[3] ? a[3] : b[3];
  final inter = ((x2 - x1) > 0 ? (x2 - x1) : 0.0) *
      ((y2 - y1) > 0 ? (y2 - y1) : 0.0);
  if (inter == 0) return 0.0;
  final areaA = (a[2] - a[0]) * (a[3] - a[1]);
  final areaB = (b[2] - b[0]) * (b[3] - b[1]);
  final union = areaA + areaB - inter;
  return union > 0 ? inter / union : 0.0;
}
