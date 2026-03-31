const express = require("express");
const multer = require("multer");
const { exec } = require("child_process");
const cors = require("cors");
const fs = require("fs");
const path = require("path");

const app = express();
app.use(cors());
app.use(express.json());

const upload = multer({ dest: "uploads/" });

// TEST
app.get("/", (req, res) => {
  res.send("Backend running");
});

// ANALYZE VIDEO
app.post("/analyze", upload.single("video"), (req, res) => {
  if (!req.file) {
    return res.status(400).send("No file uploaded");
  }

  const videoPath = req.file.path;

  exec(`python3 ai.py ${videoPath}`, (err, stdout, stderr) => {
    if (err) {
      console.error("Python error:", stderr);
      return res.status(500).send("AI failed");
    }

    try {
      const result = JSON.parse(stdout);
      fs.unlinkSync(videoPath);
      res.json(result);
    } catch (parseErr) {
      console.error("JSON parse error:", stdout);
      res.status(500).send("Invalid AI response");
    }
  });
});

app.listen(3000, () => console.log("🚀 Server running on http://localhost:3000"));
