#pragma once
#include <math.h>

struct Vector3 {
    float X, Y, Z;
    
    float Distance(Vector3 v) {
        return sqrtf(powf(v.X - X, 2) + powf(v.Y - Y, 2) + powf(v.Z - Z, 2)) / 100.0f; // Centimeters to Meters convert loop
    }
};

struct Vector2 {
    float X, Y;
};

struct FMatrix {
    float M[4][4];
};

// 4.5 Naruto Update Multi-Dimensional Matrix Formula (Bypassing game function crashing)
bool CustomWorldToScreen(Vector3 WorldLocation, FMatrix ViewMatrix, int ScreenWidth, int ScreenHeight, Vector2 &ScreenLocation) {
    float ScreenW = (ViewMatrix.M[0][3] * WorldLocation.X) + (ViewMatrix.M[1][3] * WorldLocation.Y) + (ViewMatrix.M[2][3] * WorldLocation.Z) + ViewMatrix.M[3][3];
    
    if (ScreenW < 0.001f) return false; // Enemy camera ke piche chhupa hai

    float ScreenX = (ViewMatrix.M[0][0] * WorldLocation.X) + (ViewMatrix.M[1][0] * WorldLocation.Y) + (ViewMatrix.M[2][0] * WorldLocation.Z) + ViewMatrix.M[3][0];
    float ScreenY = (ViewMatrix.M[0][1] * WorldLocation.X) + (ViewMatrix.M[1][1] * WorldLocation.Y) + (ViewMatrix.M[2][1] * WorldLocation.Z) + ViewMatrix.M[3][1];

    float CamX = ScreenWidth / 2.0f;
    float CamY = ScreenHeight / 2.0f;

    ScreenLocation.X = CamX + (CamX * ScreenX / ScreenW);
    ScreenLocation.Y = CamY - (CamY * ScreenY / ScreenW);
    
    return true;
}
