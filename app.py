from flask import Flask, render_template, send_file, abort
import io

app = Flask(__name__)
app.secret_key = "super_secret_key"

# --- MOCK DATABASE ---
# In a real app, this would be a SQLite/PostgreSQL database
ANIME_DB = {
    "medalist-season-2": {
        "title": "Medalist Season 2",
        "description": "The second season of Medalist. Witness the dazzling return to the ice as the competition heats up.",
        "tags": ["Sports", "Drama", "Seinen", "Ice Skating"],
        "rating": "8.7",
        "image": "https://placehold.co/400x600/1e293b/FFB347?text=Medalist+S2",
        "episodes": list(range(1, 10))  # 9 episodes
    },
    "fumetsu-no-anata-e-s3": {
        "title": "Fumetsu no Anata e Season 3",
        "description": "The journey of the immortal continues in a modern era.",
        "tags": ["Adventure", "Drama", "Supernatural"],
        "rating": "8.5",
        "image": "https://placehold.co/400x600/1e293b/FFB347?text=Fumetsu+S3",
        "episodes": list(range(1, 21))
    },
    "jigokuraku-2": {
        "title": "Jigokuraku 2nd Season",
        "description": "Gabimaru and the others continue their survival on the island.",
        "tags": ["Action", "Fantasy", "Historical"],
        "rating": "8.6",
        "image": "https://placehold.co/400x600/1e293b/FFB347?text=Jigokuraku+2",
        "episodes": list(range(1, 12))
    },
    "one-piece": {
        "title": "One Piece",
        "description": "Luffy and his crew continue their adventure in the New World.",
        "tags": ["Action", "Adventure", "Shounen"],
        "rating": "9.0",
        "image": "https://placehold.co/400x600/1e293b/FFB347?text=One+Piece",
        "episodes": list(range(1000, 1091))
    },
    "jujutsu-kaisen-3": {
        "title": "Jujutsu Kaisen: Shimetsu Kaiyuu",
        "description": "The Culling Game begins.",
        "tags": ["Action", "Supernatural", "School"],
        "rating": "8.9",
        "image": "https://placehold.co/400x600/1e293b/FFB347?text=Jujutsu+Kaisen",
        "episodes": list(range(1, 3))
    },
    "sousou-no-frieren-2": {
        "title": "Sousou no Frieren Season 2",
        "description": "Frieren continues her journey to Aureole.",
        "tags": ["Adventure", "Fantasy", "Slice of Life"],
        "rating": "9.2",
        "image": "https://placehold.co/400x600/1e293b/FFB347?text=Frieren+S2",
        "episodes": list(range(1, 5))
    },
    "rezero-4": {
        "title": "Re:Zero 4th Season",
        "description": "Subaru faces new challenges.",
        "tags": ["Psychological", "Fantasy", "Thriller"],
        "rating": "8.8",
        "image": "https://placehold.co/400x600/1e293b/FFB347?text=Re:Zero+S4",
        "episodes": list(range(1, 5))
    },
    "boku-no-hero-7": {
        "title": "Boku no Hero Academia 7",
        "description": "The final war approaches.",
        "tags": ["Action", "School", "Super Power"],
        "rating": "8.4",
        "image": "https://placehold.co/400x600/1e293b/FFB347?text=MHA+S7",
        "episodes": list(range(1, 10))
    }
}

SCHEDULE_ITEMS = [
    {"id": "medalist-season-2", "ep": 9, "status": "1 hour ago"},
    {"id": "fumetsu-no-anata-e-s3", "ep": 20, "status": "Episode Released"},
    {"id": "jigokuraku-2", "ep": 11, "status": "Episode Released"},
    {"id": "one-piece", "ep": 1090, "status": "Episode Released"},
    {"id": "jujutsu-kaisen-3", "ep": 2, "status": "Episode Released"},
    {"id": "sousou-no-frieren-2", "ep": 4, "status": "Episode Released"},
    {"id": "rezero-4", "ep": 3, "status": "Episode Released"},
    {"id": "boku-no-hero-7", "ep": 8, "status": "Episode Released"},
]

@app.route('/')
def home():
    # Enrich schedule items with full anime data
    full_schedule = []
    for item in SCHEDULE_ITEMS:
        anime = ANIME_DB.get(item['id'])
        if anime:
            full_schedule.append({
                "id": item['id'],
                "title": anime['title'],
                "ep": item['ep'],
                "status": item['status'],
                "image": anime['image']
            })
    return render_template('index.html', schedule=full_schedule, featured=ANIME_DB['medalist-season-2'], featured_id="medalist-season-2")

@app.route('/anime/<anime_id>')
def anime_details(anime_id):
    anime = ANIME_DB.get(anime_id)
    if not anime:
        return abort(404)
    return render_template('details.html', anime=anime, anime_id=anime_id)

@app.route('/watch/<anime_id>/<int:ep_num>')
def watch_episode(anime_id, ep_num):
    anime = ANIME_DB.get(anime_id)
    if not anime:
        return abort(404)
    # Basic check if episode exists
    if ep_num not in anime['episodes']:
        return abort(404)
    
    return render_template('watch.html', anime=anime, ep_num=ep_num, anime_id=anime_id)

@app.route('/download/<anime_id>/<int:ep_num>')
def download_episode(anime_id, ep_num):
    # DUMMY DOWNLOAD functionality
    filename = f"{anime_id}_ep{ep_num}.mp4"
    content = f"This is a dummy video file for {anime_id} Episode {ep_num}.\nIn a real app, this would be the actual video stream or file."
    return send_file(
        io.BytesIO(content.encode()),
        as_attachment=True,
        download_name=filename,
        mimetype='text/plain' 
    )

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')