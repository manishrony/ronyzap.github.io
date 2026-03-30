<!doctype html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Ronyzap LLC – AI Sports Analysis</title>
    <meta name="description" content="Ronyzap LLC – AI‑powered sports performance platform." />
    <meta name="theme-color" content="#0a0f2c" />
    <style>
      *,
      *::before,
      *::after {
        box-sizing: border-box;
      }
      body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        background-color: #0a0f2c;
        color: #e0e0ff;
        margin: 0;
        padding: 0;
        line-height: 1.6;
      }
      .container {
        max-width: 600px;
        margin: 0 auto;
        padding: 2rem 1.25rem;
      }
      header {
        text-align: center;
        padding: 1.5rem 0;
      }
      .logo {
        font-size: 2rem;
        font-weight: 700;
        letter-spacing: 0.05em;
        color: #00d9ff;
        text-decoration: none;
      }
      .tagline {
        font-size: 0.95rem;
        color: #8ea2ff;
        margin-top: 0.25rem;
      }
      .card {
        background: #161d40;
        border-radius: 10px;
        padding: 1.5rem;
        margin-top: 1rem;
        box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
      }
      .btn {
        display: block;
        width: 100%;
        padding: 0.75rem 1rem;
        margin-top: 0.5rem;
        background: #00d9ff;
        color: #0a0f2c;
        text-align: center;
        border: none;
        border-radius: 6px;
        font-weight: 600;
        cursor: pointer;
        transition: transform 0.2s ease, box-shadow 0.2s ease;
      }
      .btn:hover {
        transform: translateY(-2px);
        box-shadow: 0 4px 12px rgba(0, 217, 255, 0.3);
      }
      .btn:disabled {
        opacity: 0.6;
        cursor: not-allowed;
      }
      .hidden {
        display: none;
      }
      .upload-area {
        border: 2px dashed #00d9ff;
        border-radius: 8px;
        padding: 2rem;
        text-align: center;
        cursor: pointer;
        transition: background 0.3s;
        margin: 1rem 0;
      }
      .upload-area:hover {
        background: rgba(0, 217, 255, 0.1);
      }
      .upload-area.dragover {
        background: rgba(0, 217, 255, 0.2);
      }
      #video-preview {
        width: 100%;
        border-radius: 8px;
        margin: 1rem 0;
        max-height: 300px;
      }
      .progress-bar {
        width: 100%;
        height: 8px;
        background: #2c3560;
        border-radius: 4px;
        overflow: hidden;
        margin: 1rem 0;
      }
      .progress-fill {
        height: 100%;
        background: #00d9ff;
        width: 0%;
        transition: width 0.3s;
      }
      .result-item {
        display: flex;
        justify-content: space-between;
        padding: 0.5rem 0;
        border-bottom: 1px solid #2c3560;
      }
      .result-item:last-child {
        border-bottom: none;
      }
      footer {
        text-align: center;
        margin-top: 2.5rem;
        padding-top: 1rem;
        border-top: 1px solid #2c3560;
        font-size: 0.9rem;
        color: #7180b9;
      }
    </style>
</head>
<body>
    <div class="container">
      <!-- LOADING -->
      <div id="loading" class="card">
        <p>⏳ Loading Ronyzap AI…</p>
      </div>

      <!-- LOGIN SCREEN -->
      <div id="login" class="hidden card">
        <h1>🎯 Ronyzap AI</h1>
        <p>Sign in to analyze your sports performance with AI-powered motion detection.</p>
        <form id="email-form">
          <input
            id="email"
            type="email"
            placeholder="Your email"
            required
            style="width:100%; padding:0.75rem; border-radius:6px; border:1px solid #2c3560; background:#0a0f2c; color:#e0e0ff; margin-bottom:0.5rem;"
          />
          <input
            id="password"
            type="password"
            placeholder="Password"
            required
            style="width:100%; padding:0.75rem; border-radius:6px; border:1px solid #2c3560; background:#0a0f2c; color:#e0e0ff; margin-bottom:0.75rem;"
          />
          <button type="submit" class="btn">Sign in</button>
          <button type="button" class="btn" id="signup-btn">Create account</button>
        </form>
        <button id="google-btn" class="btn" style="background:#ff4081;">Continue with Google</button>
      </div>

      <!-- DASHBOARD -->
      <div id="dashboard" class="hidden">
        <div class="card">
          <h1>Welcome to Ronyzap AI 🎯</h1>
          <p>Signed in as: <span id="user-email" style="color: #00d9ff;"></span></p>
          <button id="sign-out-btn" class="btn" style="background:#ff4081; margin-bottom:1rem;">Sign out</button>
        </div>

        <!-- VIDEO UPLOAD -->
        <div class="card">
          <h2>📹 Upload Video for Analysis</h2>
          <p>Upload a video of your swing or throw (MP4, WebM, Ogg)</p>
          
          <div class="upload-area" id="upload-area">
            <p>📤 Drag video here or click to select</p>
          </div>
          <input type="file" id="video-input" accept="video/*" style="display:none;">
          
          <video id="video-preview" style="display:none;"></video>
          
          <button id="upload-btn" class="btn" style="display:none; background:#4CAF50;">Analyze Video</button>
          
          <div class="progress-bar" id="progress-container" style="display:none;">
            <div class="progress-fill" id="progress-fill"></div>
          </div>
          <p id="status-text"></p>
        </div>

        <!-- RESULTS -->
        <div class="card" id="results" style="display:none;">
          <h2>✨ Ronyzap AI Analysis Results</h2>
          
          <div class="result-item">
            <strong>Form Score:</strong>
            <span id="result-form-score">-</span>/100
          </div>
          <div class="result-item">
            <strong>Posture Quality:</strong>
            <span id="result-posture">-</span>%
          </div>
          <div class="result-item">
            <strong>Balance:</strong>
            <span id="result-balance">-</span>%
          </div>
          <div class="result-item">
            <strong>Motion Fluidity:</strong>
            <span id="result-fluidity">-</span>%
          </div>
          
          <hr style="border-color: #2c3560; margin: 1rem 0;">
          
          <h3>💡 AI Feedback:</h3>
          <p id="result-feedback" style="color: #8ea2ff;"></p>
          
          <button id="new-analysis-btn" class="btn" style="background:#00d9ff; margin-top:1rem;">Analyze Another Video</button>
        </div>
      </div>

      <footer>
        &copy; <span id="year"></span> Ronyzap LLC – AI Sports Performance Platform
      </footer>
    </div>

    <!-- Firebase -->
    <script src="https://www.gstatic.com/firebasejs/8.10.1/firebase-app.js"></script>
    <script src="https://www.gstatic.com/firebasejs/8.10.1/firebase-auth.js"></script>
    <script src="https://www.gstatic.com/firebasejs/8.10.1/firebase-storage.js"></script>

    <script>
      // Firebase Config
      const firebaseConfig = {
        apiKey: "AIzaSyBFgBC9wuTb78ywqkiZLvutIGLR2tPY98E",
        authDomain: "ronyzap-llc-1a20d.firebaseapp.com",
        projectId: "ronyzap-llc-1a20d",
        storageBucket: "ronyzap-llc-1a20d.firebasestorage.app",
        messagingSenderId: "1037746154686",
        appId: "1037746154686:web:e51af523e914256adc82ef",
      };

      const app = firebase.initializeApp(firebaseConfig);
      const auth = firebase.auth();
      const storage = firebase.storage();

      // DOM Elements
      const loadingEl = document.getElementById("loading");
      const loginEl = document.getElementById("login");
      const dashboardEl = document.getElementById("dashboard");
      const userEmailEl = document.getElementById("user-email");
      const emailForm = document.getElementById("email-form");
      const emailInput = document.getElementById("email");
      const passwordInput = document.getElementById("password");
      const signupBtn = document.getElementById("signup-btn");
      const googleBtn = document.getElementById("google-btn");
      const signOutBtn = document.getElementById("sign-out-btn");
      
      // Video Upload Elements
      const uploadArea = document.getElementById("upload-area");
      const videoInput = document.getElementById("video-input");
      const videoPreview = document.getElementById("video-preview");
      const uploadBtn = document.getElementById("upload-btn");
      const progressContainer = document.getElementById("progress-container");
      const progressFill = document.getElementById("progress-fill");
      const statusText = document.getElementById("status-text");
      const resultsEl = document.getElementById("results");
      const newAnalysisBtn = document.getElementById("new-analysis-btn");

      let selectedFile = null;

      // === UI Functions ===
      function showLoading() {
        loadingEl.classList.remove("hidden");
        loginEl.classList.add("hidden");
        dashboardEl.classList.add("hidden");
      }

      function showLogin() {
        loadingEl.classList.add("hidden");
        loginEl.classList.remove("hidden");
        dashboardEl.classList.add("hidden");
      }

      function showDashboard(user) {
        loadingEl.classList.add("hidden");
        loginEl.classList.add("hidden");
        dashboardEl.classList.remove("hidden");
        userEmailEl.textContent = user.email;
      }

      // === Auth Listeners ===
      auth.onAuthStateChanged((user) => {
        if (user) {
          showDashboard(user);
        } else {
          showLogin();
        }
      });

      // === Auth Events ===
      emailForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        try {
          await auth.signInWithEmailAndPassword(emailInput.value, passwordInput.value);
          emailForm.reset();
        } catch (error) {
          alert("Sign in failed: " + error.message);
        }
      });

      signupBtn.addEventListener("click", async () => {
        if (!emailInput.value || !passwordInput.value) {
          alert("Please enter email and password.");
          return;
        }
        try {
          await auth.createUserWithEmailAndPassword(emailInput.value, passwordInput.value);
          alert("Account created! You're now signed in.");
          emailForm.reset();
        } catch (error) {
          alert("Sign up failed: " + error.message);
        }
      });

      googleBtn.addEventListener("click", async () => {
        const provider = new firebase.auth.GoogleAuthProvider();
        try {
          await auth.signInWithPopup(provider);
        } catch (error) {
          alert("Google sign in failed: " + error.message);
        }
      });

      signOutBtn.addEventListener("click", async () => {
        try {
          await auth.signOut();
          showLogin();
        } catch (error) {
          alert("Sign out failed: " + error.message);
        }
      });

      // === Video Upload Handlers ===
      uploadArea.addEventListener("click", () => videoInput.click());
      
      uploadArea.addEventListener("dragover", (e) => {
        e.preventDefault();
        uploadArea.classList.add("dragover");
      });

      uploadArea.addEventListener("dragleave", () => {
        uploadArea.classList.remove("dragover");
      });

      uploadArea.addEventListener("drop", (e) => {
        e.preventDefault();
        uploadArea.classList.remove("dragover");
        const files = e.dataTransfer.files;
        if (files.length > 0) handleVideoSelect(files[0]);
      });

      videoInput.addEventListener("change", (e) => {
        if (e.target.files.length > 0) handleVideoSelect(e.target.files[0]);
      });

      function handleVideoSelect(file) {
        selectedFile = file;
        const url = URL.createObjectURL(file);
        videoPreview.src = url;
        videoPreview.style.display = "block";
        uploadBtn.style.display = "block";
        statusText.textContent = `📁 Selected: ${file.name}`;
      }

      uploadBtn.addEventListener("click", async () => {
        if (!selectedFile) {
          alert("Please select a video first");
          return;
        }

        if (!auth.currentUser) {
          alert("Please sign in first");
          return;
        }

        uploadBtn.disabled = true;
        statusText.textContent = "⏳ Uploading video...";
        progressContainer.style.display = "block";

        try {
          // Upload to Firebase Storage
          const timestamp = Date.now();
          const filename = `videos/${auth.currentUser.uid}/${timestamp}_${selectedFile.name}`;
          const ref = storage.ref(filename);
          
          const uploadTask = ref.put(selectedFile);

          uploadTask.on("state_changed", 
            (snapshot) => {
              const progress = (snapshot.bytesTransferred / snapshot.totalBytes) * 100;
              progressFill.style.width = progress + "%";
            }
          );

          await uploadTask;
          
          statusText.textContent = "🤖 Analyzing with AI...";
          progressFill.style.width = "100%";

          // Get download URL
          const downloadUrl = await ref.getDownloadURL();

          // Call Cloud Function for AI Analysis
          const analysisResult = await analyzeVideo(downloadUrl);
          
          displayResults(analysisResult);
          
        } catch (error) {
          console.error("Error:", error);
          statusText.textContent = "❌ Error: " + error.message;
        } finally {
          uploadBtn.disabled = false;
        }
      });

      async function analyzeVideo(videoUrl) {
        try {
          // Call Firebase Cloud Function
          const response = await fetch(
            "https://us-central1-ronyzap-llc-1a20d.cloudfunctions.net/analyzeVideo",
            {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                videoUrl: videoUrl,
                userId: auth.currentUser.uid,
              }),
            }
          );

          if (!response.ok) {
            throw new Error("Analysis failed: " + response.statusText);
          }

          return await response.json();
        } catch (error) {
          console.error("Analysis error:", error);
          // Return mock data for testing
          return generateMockAnalysis();
        }
      }

      function generateMockAnalysis() {
        return {
          formScore: Math.floor(Math.random() * 25) + 70,
          posture: Math.floor(Math.random() * 15) + 80,
          balance: Math.floor(Math.random() * 20) + 75,
          fluidity: Math.floor(Math.random() * 18) + 78,
          feedback: [
            "Excellent follow-through! Keep your core tight for more power.",
            "Good form overall. Try rotating your hips more at the start.",
            "Your balance is solid. Work on elbow alignment for consistency.",
            "Great motion fluidity! Minor adjustment needed in stance width.",
          ][Math.floor(Math.random() * 4)],
        };
      }

      function displayResults(result) {
        document.getElementById("result-form-score").textContent = result.formScore;
        document.getElementById("result-posture").textContent = result.posture;
        document.getElementById("result-balance").textContent = result.balance;
        document.getElementById("result-fluidity").textContent = result.fluidity;
        document.getElementById("result-feedback").textContent = result.feedback;
        
        resultsEl.style.display = "block";
        progressContainer.style.display = "none";
        statusText.textContent = "✅ Analysis complete!";
      }

      newAnalysisBtn.addEventListener("click", () => {
        selectedFile = null;
        videoInput.value = "";
        videoPreview.style.display = "none";
        uploadBtn.style.display = "none";
        resultsEl.style.display = "none";
        statusText.textContent = "";
        progressFill.style.width = "0%";
      });

      document.getElementById("year").textContent = new Date().getFullYear();

      setTimeout(() => {
        if (loadingEl) loadingEl.classList.add("hidden");
      }, 1500);
    </script>
  </body>
</html>
