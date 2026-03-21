from flask import Flask, render_template, jsonify, session
import os

app = Flask(__name__)
app.secret_key = os.environ.get('FLASK_SECRET_KEY', 'change-this-in-production')

@app.route("/")
def home():
    return render_template("index.html")

@app.route("/api/watch_episode", methods=["POST"])
def watch_episode():
    # Just tracking for session stats, no restriction
    session['eps_watched'] = session.get('eps_watched', 0) + 1
    return jsonify({"success": True, "eps_watched": session['eps_watched']})

if __name__ == "__main__":
    app.run(debug=True, host='0.0.0.0')