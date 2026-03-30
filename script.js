
function login(){
  document.getElementById("login").style.display="none";
  document.getElementById("dashboard").classList.remove("hidden");
}
function signup(){ login(); }
function logout(){
  document.getElementById("login").style.display="block";
  document.getElementById("dashboard").classList.add("hidden");
}

// VIDEO RECORDING
let mediaRecorder;
let chunks = [];

async function startRecording(){
  const stream = await navigator.mediaDevices.getUserMedia({ video:true });

  mediaRecorder = new MediaRecorder(stream);

  chunks = [];

  mediaRecorder.ondataavailable = e => {
    if (e.data.size > 0) chunks.push(e.data);
  };

  mediaRecorder.onstop = () => {
    const blob = new Blob(chunks, { type:"video/webm" }); // FIXED format
    sendToBackend(blob);
  };

  mediaRecorder.start();

  setTimeout(() => {
    mediaRecorder.stop();
  }, 5000);
}

// SEND TO BACKEND
async function sendToBackend(videoBlob){
  const formData = new FormData();
  formData.append("video", videoBlob);

  try {
    const res = await fetch("http://localhost:3000/analyze", {
      method:"POST",
      body: formData
    });

    const data = await res.json();

    console.log("AI result:", data);

    document.getElementById("speed").innerText =
      data.max_speed ? data.max_speed.toFixed(2) : "0";

  } catch (err) {
    console.error("Error:", err);
    alert("Backend not running or failed.");
  }
}
