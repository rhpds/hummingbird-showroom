from flask import Flask

app = Flask(__name__,)

@app.route("/")
def index():
    return app.send_static_file("index.html")

if __name__ == "__main__":
    # Listen on all interfaces (0.0.0.0) on port 8080
    app.run(host="0.0.0.0", port=8080)
