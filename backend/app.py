import os
import json
import logging
import time
import uuid
from datetime import datetime

import numpy as np
from PIL import Image
import torch
import torch.nn as nn
from torchvision import transforms, models
from flask import Flask, request, jsonify, Response, g
from flask_cors import CORS
from database import Database
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST


class JsonFormatter(logging.Formatter):
    """Custom JSON formatter for structured logging compatible with Loki"""
    def format(self, record):
        log_data = {
            'timestamp': datetime.utcnow().isoformat() + 'Z',
            'levelname': record.levelname,
            'name': record.name,
            'message': record.getMessage(),
            'module': record.module,
            'funcName': record.funcName,
            'lineno': record.lineno,
            'asctime': self.formatTime(record, '%Y-%m-%d %H:%M:%S,%f')[:-3]
        }
        
        # Add exception info if present
        if record.exc_info:
            log_data['exception'] = self.formatException(record.exc_info)
        
        # Add extra fields if present (e.g., request_id, user_id)
        for key in ['request_id', 'user_id', 'image_filename', 'confidence', 'prediction']:
            if hasattr(record, key):
                log_data[key] = getattr(record, key)
            
        return json.dumps(log_data)


# Configure logging with JSON formatter
handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())

logging.basicConfig(
    level=logging.INFO,
    handlers=[handler]
)

logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)


@app.before_request
def before_request():
    """Generate a unique request ID for each request for log correlation"""
    g.request_id = str(uuid.uuid4())
    logger.info(
        f"Request started: {request.method} {request.path}",
        extra={'request_id': g.request_id}
    )


@app.after_request
def after_request(response):
    """Log request completion with status code"""
    logger.info(
        f"Request completed: {request.method} {request.path} - {response.status_code}",
        extra={'request_id': g.request_id}
    )
    # Add request ID to response headers for client-side correlation
    response.headers['X-Request-ID'] = g.request_id
    return response


# Constants definitions
MODEL_PATH = os.getenv('MODEL_PATH', './models/model.pth')
LABELS_PATH = os.getenv('LABELS_PATH', './models/class_labels.json')
# MobileNetV3 typically uses 224x224 input
INPUT_SIZE = tuple(map(int, os.getenv('INPUT_SIZE', '224,224').split(',')))
MAX_IMAGE_SIZE = 10 * 1024 * 1024

# Global variables
model = None
class_labels = None
device = None
num_classes = None
db = Database()

# Prometheus metrics
REQUEST_COUNT = Counter('prediction_requests_total', 'Total prediction requests')
REQUEST_ERRORS = Counter('prediction_errors_total', 'Total prediction errors', ['error_type'])
PREDICTION_PROCESSING_TIME_MS = Histogram(
    'prediction_processing_time_ms',
    'Prediction processing time in milliseconds',
    buckets=(10, 50, 100, 250, 500, 1000, 2000, 5000)
)


@app.route('/metrics')
def metrics():
    """Prometheus metrics endpoint"""
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

def load_model():
    global model, device, num_classes
    try:
        device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
        logger.info(f"Loading {MODEL_PATH} on device {device}")
        model = models.mobilenet_v3_small(weights=None)

        if num_classes is None:
            try:
                # load locally first to try inferring number of classes
                saved = torch.load(MODEL_PATH, map_location='cpu', weights_only=True)
                if isinstance(saved, dict) and 'state_dict' in saved and isinstance(saved['state_dict'], dict):
                    saved_state = saved['state_dict']
                elif isinstance(saved, dict):
                    saved_state = saved
                else:
                    saved_state = None

                inferred_num = None
                if isinstance(saved_state, dict):
                    for k, v in saved_state.items():
                        if k.endswith('.weight') and 'classifier' in k:
                            try:
                                inferred_num = v.shape[0]
                                break
                            except Exception:
                                continue

                if inferred_num is not None:
                    num_classes = int(inferred_num)
                    logger.info(f"Inferred num_classes={num_classes} from saved state")
                else:
                    num_classes = num_classes or 1000
                    logger.info(f"Using default num_classes={num_classes}")
            except Exception:
                # on any error, fall back to default
                num_classes = num_classes or 1000
                logger.info(f"Falling back to default num_classes={num_classes}")

        try:
            # Try to replace the final linear layer to match number of classes
            if hasattr(model, 'classifier') and isinstance(model.classifier, nn.Sequential):
                last_linear_idx = None
                for i, m in enumerate(model.classifier):
                    if isinstance(m, nn.Linear):
                        last_linear_idx = i

                if last_linear_idx is not None:
                    in_features = model.classifier[last_linear_idx].in_features
                    model.classifier[last_linear_idx] = nn.Linear(in_features, int(num_classes))
                else:
                    try:
                        in_features = model.classifier[-1].in_features
                        model.classifier[-1] = nn.Linear(in_features, int(num_classes))
                    except Exception:
                        logger.warning("Could not locate classifier Linear layer by index; leaving architecture as-is")
            else:
                try:
                    if hasattr(model, 'fc') and isinstance(model.fc, nn.Linear):
                        in_features = model.fc.in_features
                        model.fc = nn.Linear(in_features, int(num_classes))
                except Exception:
                    logger.warning("Unexpected model structure; could not replace final Linear layer")
        except Exception as e:
            logger.warning(f"Error while replacing classifier layer: {e}")

        try:
            loaded = torch.load(MODEL_PATH, map_location=device, weights_only=True)

            # If the checkpoint is a dict, try to pull a state_dict
            state_dict = None
            if isinstance(loaded, dict):
                if 'state_dict' in loaded and isinstance(loaded['state_dict'], dict):
                    state_dict = loaded['state_dict']
                elif all(isinstance(v, torch.Tensor) for v in loaded.values()):
                    state_dict = loaded
            elif hasattr(loaded, 'state_dict'):
                # loaded may be a model object
                try:
                    state_dict = loaded.state_dict()
                except Exception:
                    state_dict = None

            if isinstance(state_dict, dict):
                model.load_state_dict(state_dict)
            elif hasattr(loaded, '__class__') and isinstance(loaded, nn.Module):
                # checkpoint was a full model
                model = loaded
            else:
                logger.warning("Loaded checkpoint format not recognized; attempting to proceed with initialized model")

            model.to(device)
            model.eval()

            logger.info("Model loaded successfully")
            return True
        except Exception as e:
            logger.error(f"Failed to load model state dict: {e}")
            return False
    except Exception as e:
        logger.error(f"Failed to load model: {e}")
        return False

def load_labels():
    global class_labels, num_classes
    try:
        if os.path.exists(LABELS_PATH):
            with open(LABELS_PATH, 'r') as f:
                class_labels = json.load(f)
            num_classes = len(class_labels)
            logger.info(f"Loaded {num_classes} class labels")
        else:
            logger.warning(f"No labels file found at {LABELS_PATH}")
            if num_classes is None:
                num_classes = 1000
            class_labels = [f"Class {i}" for i in range(num_classes)]
            logger.info(f"Using default labels for {num_classes} classes")
    except Exception as e:
        logger.error(f"Failed to load labels: {e}")
        if num_classes is None:
            num_classes = 1000
        class_labels = [f"Class {i}" for i in range(num_classes)]

def preprocess_image(image_file, target_size=INPUT_SIZE):
    """
    Preprocess image for PyTorch model inference.

    Returns a torch tensor on the correct device with shape (1,3,H,W).
    """
    try:
        img = Image.open(image_file)
        if img.mode != 'RGB':
            img = img.convert('RGB')

        preprocess = transforms.Compose([
            transforms.Resize(target_size),
            transforms.CenterCrop(target_size),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
        ])

        tensor = preprocess(img).unsqueeze(0)  # shape: (1,3,H,W)

        if device is not None:
            tensor = tensor.to(device)

        return tensor

    except Exception as e:
        logger.error(f"Error preprocessing image: {e}")
        raise

def predict(image_tensor, top_k=5):
    """
    Make a prediction using a preprocessed torch tensor.

    Args:
        image_tensor: torch tensor on device with shape (1,3,H,W)
        top_k: number of top results to return

    Returns:
        dict with predictions and model info
    """
    try:
        if model is None:
            raise RuntimeError("Model not loaded")

        with torch.no_grad():
            outputs = model(image_tensor)

        # if model returns tuple/list, take first element
        if isinstance(outputs, (list, tuple)):
            outputs = outputs[0]

        # Convert logits to probabilities
        probs = nn.functional.softmax(outputs, dim=1).cpu().numpy()[0]

        top_indices = np.argsort(probs)[-top_k:][::-1]
        top_scores = probs[top_indices]

        results = []
        for idx, score in zip(top_indices, top_scores):
            label = class_labels[idx] if class_labels and idx < len(class_labels) else f"Class {idx}"
            results.append({
                'class_id': int(idx),
                'label': label,
                'confidence': float(score)
            })

        return {
            'success': True,
            'predictions': results,
            'model_info': {
                'device': str(device),
                'input_shape': f"(1,3,{INPUT_SIZE[0]},{INPUT_SIZE[1]})",
                'num_classes': int(num_classes) if num_classes is not None else None
            }
        }

    except Exception as e:
        logger.error(f"Prediction error: {e}")
        return {'success': False, 'error': str(e)}

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    model_ok = model is not None
    labels_ok = class_labels is not None

    db_conn = getattr(db, 'conn', None)
    db_ok = db_conn is not None

    try:
        if db_ok and hasattr(db_conn, 'ping'):
            db_conn.ping()
        elif db_ok and hasattr(db_conn, 'cursor'):
            with db_conn.cursor() as cur:
                cur.execute('SELECT 1')
    except Exception:
        db_ok = False

    payload = {
        'status': 'healthy' if (model_ok and labels_ok and db_ok) else 'unhealthy',
        'model_loaded': model_ok,
        'labels_loaded': labels_ok,
        'db_connected': db_ok
    }

    # Log payload content
    try:
        logger.info("Health check payload: %s", json.dumps(payload))
    except Exception:
        logger.info("Health check payload: %s", str(payload))

    return (jsonify(payload), 200) if payload['status'] == 'healthy' else (jsonify(payload), 503)


@app.route('/info', methods=['GET'])
def model_info():
    """Return model information"""
    if model is None:
        return jsonify({'error': 'Model not loaded'}), 500
    # Avoid accessing model internals that may not be present across different architectures.
    return jsonify({
        'model_path': MODEL_PATH,
        'model_loaded': True,
        'device': str(device),
        'num_classes': int(num_classes) if num_classes is not None else None,
        'labels_available': class_labels is not None,
        'input_size': INPUT_SIZE
    })


@app.route('/predict', methods=['POST'])
def predict_endpoint():
    """
    API Endpoint for uploading plant images for classification

    Usage:
    curl -X POST -F "image=@/path/to/your/image.jpg" http://localhost:8000/predict

    """
    if model is None:
        REQUEST_ERRORS.labels(error_type='model_not_loaded').inc()
        return jsonify({
            'success': False,
            'error': 'Model not loaded'
        }), 500
    
    if 'image' not in request.files:
        REQUEST_ERRORS.labels(error_type='no_image_provided').inc()
        return jsonify({
            'success': False,
            'error': 'No image file provided. Please upload an image using the "image" field.'
        }), 400
    
    file = request.files['image']
    
    if file.filename == '':
        REQUEST_ERRORS.labels(error_type='empty_filename').inc()
        return jsonify({
            'success': False,
            'error': 'Empty filename'
        }), 400
    
    file.seek(0, os.SEEK_END)
    file_size = file.tell()
    file.seek(0)
    
    if file_size > MAX_IMAGE_SIZE:
        REQUEST_ERRORS.labels(error_type='file_too_large').inc()
        return jsonify({
            'success': False,
            'error': f'File too large. Maximum size is {MAX_IMAGE_SIZE / (1024*1024)}MB'
        }), 400
    
    top_k = request.form.get('top_k', 5, type=int)
    max_k = None
    if num_classes is not None:
        max_k = int(num_classes)
    elif class_labels is not None:
        max_k = len(class_labels)
    else:
        max_k = 1000

    top_k = min(max(1, top_k), max_k)
    
    try:
        # Record that a prediction request was received
        REQUEST_COUNT.inc()

        logger.info(
            f"Processing image: {file.filename}",
            extra={'request_id': g.request_id, 'image_filename': file.filename}
        )

        # timing for processing
        start_ts = time.time()
        img_array = preprocess_image(file, target_size=INPUT_SIZE)

        result = predict(img_array, top_k=top_k)
        processing_time_ms = (time.time() - start_ts) * 1000.0

        result['filename'] = file.filename
        result['request_id'] = g.request_id
        result.setdefault('model_info', {})
        result['model_info']['processing_time_ms'] = processing_time_ms

        # Observe processing time in Prometheus histogram (ms)
        try:
            PREDICTION_PROCESSING_TIME_MS.observe(processing_time_ms)
        except Exception:
            # metrics should never break the request flow
            logger.debug("Failed to record processing time metric")

        try:
            if not getattr(db, 'conn', None):
                db.connect()

            if result.get('success') and result.get('predictions'):
                top = result['predictions'][0]
                saved = db.save_prediction(
                    image_name=file.filename,
                    prediction=top.get('label') if isinstance(top, dict) else str(top),
                    confidence=float(top.get('confidence', 0.0)) if isinstance(top, dict) else 0.0,
                    top_5=result.get('predictions'),
                    image_size=file_size,
                )

                if saved:
                    # attach DB metadata
                    result['history_record'] = saved
        except Exception as e:
            logger.warning(
                f"Could not persist history: {e}",
                extra={'request_id': g.request_id}
            )

        logger.info(
            f"Prediction successful: {result['predictions'][0]['label']} "
            f"({result['predictions'][0]['confidence']*100:.2f}%)",
            extra={
                'request_id': g.request_id,
                'image_filename': file.filename,
                'prediction': result['predictions'][0]['label'],
                'confidence': result['predictions'][0]['confidence']
            }
        )

        return jsonify(result)
    
    except Exception as e:
        REQUEST_ERRORS.labels(error_type='processing_error').inc()
        logger.error(f"Error processing request: {e}")
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/history', methods=['GET'])
def get_history():
    """Return prediction history from database (limit/offset supported)."""
    try:
        limit = request.args.get('limit', 50, type=int)
        offset = request.args.get('offset', 0, type=int)

        if not getattr(db, 'conn', None):
            db.connect()

        history = db.get_history(limit=limit, offset=offset)
        return jsonify(history), 200
    except Exception as e:
        logger.error(f"Error fetching history: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/history', methods=['DELETE'])
def clear_history():
    """Clear prediction history in the database."""
    try:
        if not getattr(db, 'conn', None):
            db.connect()

        deleted = db.clear_history()
        return jsonify({'message': 'History cleared', 'deleted_count': deleted}), 200
    except Exception as e:
        logger.error(f"Error clearing history: {e}")
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    logger.info("Starting model hosting...")
    
    load_labels()

    if not load_model():
        logger.error("Failed to load model. Exiting...")
        exit(1)
    try:
        db.connect()
    except Exception:
        logger.warning("Database connection failed at startup; continuing without DB")

    port = int(os.getenv('PORT', 8000))
    logger.info(f"Starting server on port {port}")
    
    app.run(
        host='0.0.0.0',
        port=port,
        debug=os.getenv('DEBUG', 'False').lower() == 'true'
    )