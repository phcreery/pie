// https://github.com/kooparse/zalgebra/blob/main/src/mat3.zig

/// Calculate determinant of the given 3x3 matrix.
pub fn det(T: type, data: [3][3]T) T {
    var s: [3]T = undefined;
    s[0] = data[0][0] * (data[1][1] * data[2][2] - data[1][2] * data[2][1]);
    s[1] = data[0][1] * (data[1][0] * data[2][2] - data[1][2] * data[2][0]);
    s[2] = data[0][2] * (data[1][0] * data[2][1] - data[1][1] * data[2][0]);
    return s[0] - s[1] + s[2];
}

/// Construct inverse 3x3 from given matrix.
/// Note: This is not the most efficient way to do this.
/// TODO: Make it more efficient.
pub fn inv(T: type, data: [3][3]T) [3][3]T {
    var inv_mat: [3][3]T = undefined;

    const determ = 1 / det(T, data);

    inv_mat[0][0] = determ * (data[1][1] * data[2][2] - data[1][2] * data[2][1]);
    inv_mat[0][1] = determ * -(data[0][1] * data[2][2] - data[0][2] * data[2][1]);
    inv_mat[0][2] = determ * (data[0][1] * data[1][2] - data[0][2] * data[1][1]);

    inv_mat[1][0] = determ * -(data[1][0] * data[2][2] - data[1][2] * data[2][0]);
    inv_mat[1][1] = determ * (data[0][0] * data[2][2] - data[0][2] * data[2][0]);
    inv_mat[1][2] = determ * -(data[0][0] * data[1][2] - data[0][2] * data[1][0]);

    inv_mat[2][0] = determ * (data[1][0] * data[2][1] - data[1][1] * data[2][0]);
    inv_mat[2][1] = determ * -(data[0][0] * data[2][1] - data[0][1] * data[2][0]);
    inv_mat[2][2] = determ * (data[0][0] * data[1][1] - data[0][1] * data[1][0]);

    return inv_mat;
}
