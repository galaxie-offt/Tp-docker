from flask import Flask, jsonify
import os
import pymysql

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "db")
DB_USER = os.environ.get("DB_USER", "appuser")
DB_PASS = os.environ.get("DB_PASS", "apppass")
DB_NAME = os.environ.get("DB_NAME", "appdb")

@app.route("/")
def index():
    return "Hello from app!"

@app.route("/health")
def health():
    try:
        conn = pymysql.connect(host=DB_HOST, user=DB_USER, password=DB_PASS, database=DB_NAME, connect_timeout=3)
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        return jsonify(status="ok", db="reachable")
    except Exception as e:
        return jsonify(status="error", error=str(e)), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
