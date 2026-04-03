let sessionData = [];
let topSpeed = 0;

async function uploadVideo() {
  const fileInput = document.getElementById("fileInput");
  if (!fileInput.files[0]) return alert("Select a video first");

  const file = fileInput.files[0];
  const formData = new FormData();
  formData.append("video", file);

  const res = await fetch("http://localhost:5000/upload", {
    method: "POST",
    body: formData
  });

  const data = await res.json();

  document.getElementById("speed").innerText = data.speed;
  if (data.speed > topSpeed) topSpeed = data.speed;
  document.getElementById("topSpeed").innerText = topSpeed;

  sessionData.push(data.speed);
  const avg = (sessionData.reduce((a,b)=>a+b,0)/sessionData.length).toFixed(1);
  document.getElementById("avgSpeed").innerText = avg;

  // Update recent sessions
  const recentList = document.getElementById("recentSessions");
  recentList.innerHTML = "";
  sessionData.slice(-5).reverse().forEach((s,i)=>{
    const li = document.createElement("li");
    li.innerText = `Session ${sessionData.length-i}: ${s} MPH`;
    recentList.appendChild(li);
  });

  // Update chart
  updateChart(sessionData);

  // Video playback
  const video = document.getElementById("resultVideo");
  video.src = "http://localhost:5000" + data.video_url;
}

// Chart.js
let chart;
function updateChart(data) {
  const ctx = document.getElementById('speedChart').getContext('2d');
  if(chart) chart.destroy();
  chart = new Chart(ctx, {
    type: 'line',
    data: {
      labels: data.map((_,i)=>`Session ${i+1}`),
      datasets: [{
        label: 'Max Speed (MPH)',
        data: data,
        backgroundColor: 'rgba(0,255,204,0.2)',
        borderColor: '#00ffcc',
        borderWidth: 2,
        fill: true,
        tension: 0.3
      }]
    },
    options: {
      responsive: true,
      scales: {
        y: { beginAtZero: true }
      }
    }
  });
}
