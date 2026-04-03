import cv2
import numpy as np
import time
from collections import deque

class RonyzapAI:
    def __init__(self, video_path, output_path):
        self.cap = cv2.VideoCapture(video_path)
        self.output_path = output_path
        self.ball_positions = deque(maxlen=25)
        self.prev_time = time.time()
        self.pixels_per_meter = 220
        self.frame_count = 0

        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        fps = int(self.cap.get(cv2.CAP_PROP_FPS)) or 30
        width = int(self.cap.get(3))
        height = int(self.cap.get(4))
        self.out = cv2.VideoWriter(output_path, fourcc, fps, (width, height))

    def detect_ball(self, frame):
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        lower = np.array([15, 80, 80])
        upper = np.array([50, 255, 255])
        mask = cv2.inRange(hsv, lower, upper)
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if contours:
            largest = max(contours, key=cv2.contourArea)
            if cv2.contourArea(largest) > 80:
                (x, y), radius = cv2.minEnclosingCircle(largest)
                return int(x), int(y), int(radius)
        return None

    def calculate_speed(self, pos1, pos2, dt):
        if dt <= 0: return 0.0
        pixel_dist = np.hypot(pos2[0]-pos1[0], pos2[1]-pos1[1])
        dist_meters = pixel_dist / self.pixels_per_meter
        speed_mps = dist_meters / dt
        return speed_mps * 2.237

    def run(self):
        max_speed = 0
        while True:
            ret, frame = self.cap.read()
            if not ret: break
            self.frame_count +=1
            dt = time.time() - self.prev_time
            self.prev_time = time.time()
            ball = self.detect_ball(frame)
            if ball:
                x, y, r = ball
                self.ball_positions.append((x, y))
                cv2.circle(frame, (x, y), r, (0, 255, 0), 3)
                if len(self.ball_positions) >= 4:
                    pos1 = self.ball_positions[-4]
                    pos2 = self.ball_positions[-1]
                    speed = self.calculate_speed(pos1, pos2, dt*1.8)
                    if speed > max_speed: max_speed = speed
                    if speed > 30:
                        cv2.putText(frame,f"{speed:.1f} mph",(x-60,y+70),
                                    cv2.FONT_HERSHEY_SIMPLEX,1.2,(0,0,255),3)
            self.out.write(frame)
        self.cap.release()
        self.out.release()
        return round(max_speed,1)
