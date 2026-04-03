from flask import Flask, request, jsonify, send_file
import os
from ai import RonyzapAI

app = Flask(__name__)
UPLOAD_FOLDER = "uploads"
OUTPUT_FOLDER = "outputs"
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
os.makedirs(OUTPUT_FOLDER, exist_ok=True)

@app.route("/upload", methods=["POST"])
def upload_video():
    file = request.files["video"]
    input_path = os.path.join(UPLOAD_FOLDER, file.filename)
    output_path = os.path.join(OUTPUT_FOLDER, "processed_" + file.filename)
    file.save(input_path)
    ai = RonyzapAI(input_path, output_path)
    speed = ai.run()
    return jsonify({
        "speed": speed,
        "video_url": f"/video/{file.filename}"
    })

@app.route("/video/<filename>")
def get_video(filename):
    return send_file(os.path.join(OUTPUT_FOLDER, "processed_" + filename))

if __name__ == "__main__":
    app.run(debug=True)
