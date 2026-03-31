import cv2
import sys
import json
import numpy as np

# SAFE ARG CHECK
if len(sys.argv) < 2:
    print(json.dumps({"error": "No video path provided"}))
    sys.exit(0)

video_path = sys.argv[1]

cap = cv2.VideoCapture(video_path)

if not cap.isOpened():
    print(json.dumps({"error": "Could not open video"}))
    sys.exit(0)

positions = []
fps = cap.get(cv2.CAP_PROP_FPS)

if fps == 0:
    fps = 30

while cap.isOpened():
    ret, frame = cap.read()
    if not ret:
        break

    hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)

    lower = np.array([20, 100, 100])
    upper = np.array([35, 255, 255])

    mask = cv2.inRange(hsv, lower, upper)

    contours, _ = cv2.findContours(mask, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE)

    if contours:
        largest = max(contours, key=cv2.contourArea)
        (x, y), radius = cv2.minEnclosingCircle(largest)

        if radius > 5:
            positions.append((x, y))

cap.release()

# SPEED CALC
speeds = []
for i in range(1, len(positions)):
    x1, y1 = positions[i-1]
    x2, y2 = positions[i]

    dist = ((x2-x1)**2 + (y2-y1)**2) ** 0.5
    speed = dist * fps
    speeds.append(speed)

avg_speed = sum(speeds)/len(speeds) if speeds else 0
max_speed = max(speeds) if speeds else 0

print(json.dumps({
    "avg_speed": avg_speed,
    "max_speed": max_speed,
    "points": positions[:50]
}))
