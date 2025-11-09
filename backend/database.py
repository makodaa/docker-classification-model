import logging
import psycopg2
from psycopg2.extras import RealDictCursor
import json
import os
logger = logging.getLogger(__name__)

if not logger.handlers:
    # basic fallback configuration when module used standalone
    logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')

class Database:
    def __init__(self):
        self.connection_string = os.getenv(
            'DATABASE_URL',
            'postgresql://classifier_user:secure_password@database:5432/classifier_db'
        )
        self.conn = None
        
    def connect(self):
        """Establish database connection"""
        try:
            self.conn = psycopg2.connect(self.connection_string)
            # ensure table exists
            self._ensure_table()
            logger.info("Database connected successfully")
            return True
        except Exception as e:
            logger.error(f"Database connection failed: {e}")
            return False
    
    def disconnect(self):
        """Close database connection"""
        if self.conn:
            self.conn.close()
            logger.info("Database connection closed")
    
    def save_prediction(self, image_name, prediction, confidence, top_5, image_size=None):
        """Save a prediction to the database"""
        if not self.conn:
            connected = self.connect()
            if not connected:
                logger.warning("Not connected to DB; cannot save prediction")
                return None
        cursor = None
        try:
            cursor = self.conn.cursor()

            # Convert top_5 predictions to JSON
            top_5_json = json.dumps(top_5)

            # Only store image_name, prediction, confidence and top_5_predictions
            query = """
                INSERT INTO predictions
                (image_name, prediction, confidence, top_5_predictions)
                VALUES (%s, %s, %s, %s)
                RETURNING id, timestamp
            """

            cursor.execute(query, (
                image_name,
                prediction,
                confidence,
                top_5_json,
            ))

            result = cursor.fetchone()
            self.conn.commit()

            if result:
                saved = {
                    'id': result[0],
                    'timestamp': result[1].isoformat() if result[1] is not None else None
                }
                logger.info(f"Saved prediction id={saved['id']} image={image_name} confidence={confidence}")
                return saved
            else:
                logger.warning("Insert returned no result")
                return None

        except Exception as e:
            # rollback only if we have an active connection
            try:
                if self.conn:
                    self.conn.rollback()
            except Exception:
                pass
            logger.error(f"Error saving prediction: {e}")
            return None
        finally:
            if cursor is not None:
                try:
                    cursor.close()
                except Exception:
                    pass
    
    def get_history(self, limit=50, offset=0):
        """Retrieve prediction history"""
        if not self.conn:
            connected = self.connect()
            if not connected:
                logger.warning("Not connected to DB; get_history returning empty list")
                return []
        
        cursor = None
        try:
            cursor = self.conn.cursor(cursor_factory=RealDictCursor)

            query = """
                SELECT
                    id,
                    timestamp,
                    image_name,
                    prediction,
                    confidence,
                    top_5_predictions
                FROM predictions
                ORDER BY timestamp DESC
                LIMIT %s OFFSET %s
            """

            cursor.execute(query, (limit, offset))
            results = cursor.fetchall()

            # Convert to list of dicts with proper formatting
            history = []
            for row in results:
                # top_5_predictions may be stored as JSON (text) or native jsonb
                top5 = row.get('top_5_predictions')
                try:
                    if isinstance(top5, str):
                        top5 = json.loads(top5)
                except Exception:
                    pass

                history.append({
                    'id': row['id'],
                    'timestamp': row['timestamp'].isoformat() if row['timestamp'] is not None else None,
                    'image_name': row['image_name'],
                    'prediction': row['prediction'],
                    'confidence': float(row['confidence']) if row['confidence'] is not None else None,
                    'top_5_predictions': top5,
                })

            return history

        except Exception as e:
            logger.error(f"Error retrieving history: {e}")
            return []
        finally:
            if cursor is not None:
                try:
                    cursor.close()
                except Exception:
                    pass
    
    def clear_history(self):
        """Clear all prediction history"""
        if not self.conn:
            connected = self.connect()
            if not connected:
                logger.warning("Not connected to DB; clear_history nothing to do")
                return 0
        
        cursor = None
        try:
            cursor = self.conn.cursor()
            cursor.execute("DELETE FROM predictions")
            deleted_count = cursor.rowcount
            self.conn.commit()
            return deleted_count
        except Exception as e:
            try:
                if self.conn:
                    self.conn.rollback()
            except Exception:
                pass
            logger.error(f"Error clearing history: {e}")
            return 0
        finally:
            if cursor is not None:
                try:
                    cursor.close()
                except Exception:
                    pass
    
    def get_stats(self):
        """Get statistics about predictions"""
        if not self.conn:
            connected = self.connect()
            if not connected:
                logger.warning("Not connected to DB; get_stats returning empty dict")
                return {}
        
        cursor = None
        try:
            cursor = self.conn.cursor(cursor_factory=RealDictCursor)

            # total and average
            cursor.execute('SELECT COUNT(*) as total_predictions, AVG(confidence) as avg_confidence FROM predictions')
            totals = cursor.fetchone()

            # most common class
            cursor.execute('SELECT prediction, COUNT(*) as class_count FROM predictions GROUP BY prediction ORDER BY class_count DESC LIMIT 1')
            top = cursor.fetchone()

            stats = {
                'total_predictions': int(totals['total_predictions']) if totals and totals.get('total_predictions') is not None else 0,
                'avg_confidence': float(totals['avg_confidence']) if totals and totals.get('avg_confidence') is not None else None,
            }
            if top:
                stats.update({'most_common_class': top.get('prediction'), 'most_common_count': int(top.get('class_count', 0))})
            return stats
        except Exception as e:
            logger.error(f"Error getting stats: {e}")
            return {}
        finally:
            if cursor is not None:
                try:
                    cursor.close()
                except Exception:
                    pass

    def _ensure_table(self):
        """Create predictions table if it does not exist."""
        if not self.conn:
            return
        cur = None
        try:
            cur = self.conn.cursor()
            create_sql = '''
            CREATE TABLE IF NOT EXISTS predictions (
                id SERIAL PRIMARY KEY,
                timestamp TIMESTAMPTZ DEFAULT now(),
                image_name TEXT,
                prediction TEXT,
                confidence REAL,
                top_5_predictions JSONB
            );
            '''
            cur.execute(create_sql)
            self.conn.commit()
        except Exception as e:
            logger.error(f"Error ensuring predictions table exists: {e}")
        finally:
            if cur is not None:
                try:
                    cur.close()
                except Exception:
                    pass