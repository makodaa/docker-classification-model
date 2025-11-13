document.getElementById("image-input").addEventListener("change", (e) => {
    const file = e.target.files[0];
    if (file) {
        displayImagePreview(file);
    }
});

function displayImagePreview(file) {
    const imageDisplay = document.querySelector(".image-display");
    const reader = new FileReader();

    reader.onload = (e) => {
        imageDisplay.innerHTML = `
      <img src="${e.target.result}" alt="Preview" style="max-width: 100%; max-height: 300px; border-radius: 4px;">
    `;
        imageDisplay.classList.remove("hidden");
    };

    reader.readAsDataURL(file);
}

async function handleUpload() {
    const fileInput = document.getElementById("image-input");
    const file = fileInput.files[0];

    if (!file) {
        alert("Please select an image file");
        return;
    }

    // Validate file type
    if (!file.type.startsWith("image/")) {
        alert("Please select a valid image file (jpg, png, jpeg)");
        return;
    }

    // Validate file size (max 10MB)
    if (file.size > 10 * 1024 * 1024) {
        alert("Image size must be less than 10MB");
        return;
    }

    const formData = new FormData();
    formData.append("image", file);

    try {
        showLoading();

        // Use the nginx proxy (/api/) so this works from the container
        const response = await fetch("/api/predict", {
            method: "POST",
            body: formData,
        });

        if (!response.ok) {
            const text = await response.text().catch(() => null);
            throw new Error(
                `HTTP error! status: ${response.status} ${text || ""}`
            );
        }

        const result = await response.json();
        console.log(result);
        displayResults(result);

        await loadHistory();
    } catch (error) {
        console.error("Prediction failed:", error);
        displayError("Failed to classify image. Please try again.");
    } finally {
        hideLoading();
    }
}

function showLoading() {
    const resultList = document.getElementById("result-list");
    resultList.innerHTML = `
    <div class="loading-container">
      <div class="spinner"></div>
      <p>Classifying image...</p>
    </div>
  `;
}

function hideLoading() {
    // Loading will be replaced by results or error
    // This function can be used for cleanup if needed
}

function displayResults(result) {
    const resultList = document.getElementById("result-list");

    if (!result || !result.predictions) {
        displayError("Invalid response from server");
        return;
    }

    const predictions = result.predictions;
    const topPrediction = predictions[0];

    resultList.innerHTML = `
    <div class="result-container">
      <div class="top-prediction">
        <h4>Top Prediction</h4>
        <div class="prediction-main">
          <span class="prediction-class">${topPrediction.label}</span>
          <span class="prediction-confidence">${(
              topPrediction.confidence * 100
          ).toFixed(2)}%</span>
        </div>
      </div>
      
      <div class="all-predictions">
        <h4>Top 5 Predictions</h4>
        ${predictions
            .slice(0, 5)
            .map(
                (pred, index) => `
          <div class="prediction-item">
            <div class="prediction-rank">${index + 1}</div>
            <div class="prediction-details">
              <div class="prediction-info">
                <span class="pred-class">${pred.label}</span>
                <span class="pred-confidence">${(pred.confidence * 100).toFixed(
                    2
                )}%</span>
              </div>
              <div class="progress-bar">
                <div class="progress-fill" style="width: ${
                    pred.confidence * 100
                }%"></div>
              </div>
            </div>
          </div>
        `
            )
            .join("")}
      </div>
      
      ${(() => {
          const ms =
              (result &&
                  result.model_info &&
                  result.model_info.processing_time_ms) ||
              result.processing_time ||
              null;
          return ms
              ? `
        <div class="metadata">
          <small>Processing time: ${ms.toFixed(2)}ms</small>
        </div>
      `
              : "";
      })()}
    </div>
  `;
}

function displayError(message) {
    const resultList = document.getElementById("result-list");
    resultList.innerHTML = `
    <div class="error-container">
      <p class="error-message">❌ ${message}</p>
    </div>
  `;
}

async function loadHistory() {
    try {
        const response = await fetch("/api/history");

        if (!response.ok) {
            throw new Error("Failed to load history");
        }

        const historyData = await response.json();
        displayHistory(historyData);
    } catch (error) {
        console.error("Failed to load history:", error);
        displayHistoryError();
    }
}

function displayHistory(historyData) {
    const historyList = document.getElementById("history-list");

    if (!historyData || historyData.length === 0) {
        historyList.innerHTML =
            '<p class="empty-state">No classification history yet</p>';
        return;
    }

    historyList.innerHTML = historyData
        .map(
            (item, index) => `
    <div class="history-card">
      <div class="history-header-item">
        <span class="history-number">#${historyData.length - index}</span>
        <span class="history-time">${formatTimestamp(item.timestamp)}</span>
      </div>
      <div class="history-content">
        <div class="history-main">
          <strong>${item.prediction}</strong>
          <span class="confidence-badge">${(item.confidence * 100).toFixed(
              1
          )}%</span>
        </div>
        <div class="history-meta">
          <span>file: ${item.image_name}</span>
        </div>
      </div>
    </div>
  `
        )
        .join("");
}

function displayHistoryError() {
    const historyList = document.getElementById("history-list");
    historyList.innerHTML = '<p class="error-state">Failed to load history</p>';
}

function formatTimestamp(timestamp) {
    const date = new Date(timestamp);
    const now = new Date();
    const diffMs = now - date;
    const diffMins = Math.floor(diffMs / 60000);

    if (diffMins < 1) return "Just now";
    if (diffMins < 60) return `${diffMins} min ago`;
    if (diffMins < 1440) return `${Math.floor(diffMins / 60)} hours ago`;

    return (
        date.toLocaleDateString() +
        " " +
        date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
    );
}

async function clearHistory() {
    if (
        !confirm(
            "Are you sure you want to clear all classification history? This action cannot be undone."
        )
    )
        return;

    const button = document.getElementById("clear-history-btn");
    const originalText = button.textContent;

    try {
        button.disabled = true;
        button.textContent = "Clearing...";

        const response = await fetch("/api/history", {
            method: "DELETE",
        });

        if (!response.ok) {
            throw new Error("Failed to clear history");
        }

        const result = await response.json();
        console.log(`Cleared ${result.deleted_count || 0} history records`);

        // Refresh display
        await loadHistory();

        // Show success feedback
        button.textContent = "Cleared!";
        setTimeout(() => {
            button.textContent = originalText;
        }, 2000);
    } catch (error) {
        console.error("Failed to clear history:", error);
        alert("Failed to clear history: " + error.message);
        button.textContent = originalText;
    } finally {
        button.disabled = false;
    }
}

document.addEventListener("DOMContentLoaded", () => {
    loadHistory();
});
