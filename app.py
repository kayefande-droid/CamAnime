import requests
import random
import time
from flask import Flask, request, render_template_string, redirect, url_for

app = Flask(__name__)

# Base URL for Consumet API
CONSUMET_API = "https://api.consumet.org"

# HTML Template for the Watch Page
WATCH_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Watch {{ anime_title }}</title>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet">
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; background: #0a0a0a; color: white; }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        
        header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; border-bottom: 1px solid #333; padding-bottom: 10px; }
        .logo { color: #FFB347; font-weight: 800; font-size: 1.5rem; text-decoration: none; }
        
        h1 { font-size: 1.5rem; margin-bottom: 10px; color: #eef2ff; }
        
        .video-container { position: relative; width: 100%; padding-top: 56.25%; background: #000; border-radius: 12px; overflow: hidden; box-shadow: 0 10px 30px rgba(0,0,0,0.5); }
        video, iframe { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: none; }
        
        .controls { display: flex; justify-content: space-between; align-items: center; margin-top: 15px; background: #1e1e1e; padding: 15px; border-radius: 8px; flex-wrap: wrap; gap: 10px; }
        
        .episode-selector label { font-weight: bold; margin-right: 10px; color: #FFB347; }
        select { padding: 8px 12px; border-radius: 5px; border: 1px solid #444; background: #222; color: white; font-size: 1rem; cursor: pointer; }
        
        .nav-btn { background: #333; color: white; text-decoration: none; padding: 8px 16px; border-radius: 5px; transition: 0.2s; font-weight: 600; }
        .nav-btn:hover { background: #FFB347; color: black; }
        .nav-btn.disabled { opacity: 0.5; pointer-events: none; }
        
        .error { color: #ff6b6b; background: rgba(255, 107, 107, 0.1); padding: 15px; border-radius: 8px; margin: 20px 0; border: 1px solid #ff6b6b; }
        
        .footer { margin-top: 40px; text-align: center; font-size: 0.8rem; color: #777; border-top: 1px solid #222; padding-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <a href="/" class="logo">Camanime</a>
            <a href="/" class="nav-btn">Home</a>
        </header>

        <h1>{{ anime_title }}</h1>
        
        <div class="video-container">
            {% if video_url %}
                {% if is_iframe %}
                    <iframe src="{{ video_url }}" allowfullscreen></iframe>
                {% else %}
                    <video controls autoplay>
                        <source src="{{ video_url }}" type="application/x-mpegURL">
                        <source src="{{ video_url }}" type="video/mp4">
                        Your browser does not support the video tag.
                    </video>
                {% endif %}
            {% else %}
                <div style="display: flex; align-items: center; justify-content: center; height: 100%; color: #ff6b6b;">
                    <p>Video source not found. Please try another episode.</p>
                </div>
            {% endif %}
        </div>

        {% if error_msg %}
            <div class="error">
                ❌ {{ error_msg }}
            </div>
        {% endif %}

        <div class="controls">
            <a href="/watch/{{ anime_id }}/{{ episode - 1 }}" class="nav-btn {{ 'disabled' if episode <= 1 else '' }}">
                <i class="fas fa-chevron-left"></i> Prev
            </a>
            
            <div class="episode-selector">
                <label for="episode">Episode:</label>
                <select id="episode" onchange="location.href='/watch/{{ anime_id }}/' + this.value">
                    {% for ep in episodes %}
                        <option value="{{ ep.number }}" {% if ep.number == episode %}selected{% endif %}>
                            Episode {{ ep.number }}
                        </option>
                    {% endfor %}
                </select>
            </div>

            <a href="/watch/{{ anime_id }}/{{ episode + 1 }}" class="nav-btn">
                Next <i class="fas fa-chevron-right"></i>
            </a>
        </div>

        <div class="footer">
            ⚡ Powered by Consumet API | Streams from VidCloud/VidStream + Gogoanime fallback
        </div>
    </div>
</body>
</html>
"""

def fetch_episode_sources(anime_id, episode):
    """
    Tries to get a working video URL for the given anime ID and episode number.
    Returns: (video_url, anime_title, episodes_list, is_iframe, error_message)
    """
    video_url = None
    anime_title = f"Anime {anime_id}"
    episodes = []
    is_iframe = False
    error_msg = None

    try:
        # 1. Get Anime Info (Metadata & Episode List)
        info_url = f"{CONSUMET_API}/meta/anilist/info/{anime_id}"
        info_resp = requests.get(info_url, timeout=10)
        
        if info_resp.status_code == 200:
            anime_data = info_resp.json()
            anime_title = anime_data.get('title', {}).get('romaji', anime_title)
            episodes = anime_data.get('episodes', [])
            
            # Find specific episode ID
            episode_obj = next((ep for ep in episodes if ep.get('number') == episode), None)
            
            if episode_obj:
                episode_id = episode_obj.get('id')
                
                # 2. Try Primary Source (VidStream/VidCloud)
                try:
                    watch_url = f"{CONSUMET_API}/meta/anilist/watch/{episode_id}"
                    watch_resp = requests.get(watch_url, timeout=8)
                    if watch_resp.status_code == 200:
                        sources = watch_resp.json().get('sources', [])
                        # Prefer 'default' or 'backup' quality
                        best_src = next((s for s in sources if s.get('quality') == 'default'), None)
                        if not best_src and sources:
                            best_src = sources[0]
                        
                        if best_src:
                            video_url = best_src['url']
                except Exception as e:
                    print(f"Primary source error: {e}")

                # 3. Fallback: Gogoanime (if primary failed)
                if not video_url:
                    print(f"Primary failed for {anime_id} ep {episode}, trying Gogoanime fallback...")
                    try:
                        # Gogoanime search/info might be needed if IDs differ, but Consumet often maps AniList IDs
                        # Alternatively, use vidsrc embed as a foolproof fallback
                        video_url = f"https://vidsrc.cc/v2/embed/anime/{anime_id}/{episode}"
                        is_iframe = True
                    except Exception as e:
                        print(f"Fallback error: {e}")

            else:
                error_msg = f"Episode {episode} not found in anime data."
        else:
             error_msg = "Could not fetch anime details."

    except Exception as e:
        error_msg = f"System Error: {str(e)}"

    # Cache Busting (only for direct video files, not iframes)
    if video_url and not is_iframe:
         separator = '&' if '?' in video_url else '?'
         video_url += f"{separator}cache_buster={random.randint(100000, 999999)}"

    return video_url, anime_title, episodes, is_iframe, error_msg

@app.route('/')
def index():
    return render_template_string("""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Camanime - Home</title>
        <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet">
        <style>
            body { font-family: 'Segoe UI', sans-serif; background: #0a0c15; color: white; text-align: center; padding: 2rem; margin: 0; }
            .container { max-width: 800px; margin: 0 auto; }
            h1 { font-size: 3rem; margin-bottom: 2rem; background: linear-gradient(135deg, #FFB347, #FF6B6B); -webkit-background-clip: text; color: transparent; }
            
            .search-box { display: flex; gap: 10px; justify-content: center; margin-bottom: 3rem; }
            input { padding: 15px; border-radius: 30px; border: none; width: 60%; background: #1e263a; color: white; font-size: 1.1rem; outline: none; }
            button { padding: 15px 30px; border-radius: 30px; border: none; background: #FFB347; color: black; font-weight: bold; cursor: pointer; font-size: 1.1rem; transition: 0.2s; }
            button:hover { transform: scale(1.05); }

            .quick-links { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 1rem; margin-top: 2rem; }
            .anime-card { background: #1e263a; padding: 1rem; border-radius: 12px; text-decoration: none; color: white; transition: 0.2s; border: 1px solid rgba(255,255,255,0.05); }
            .anime-card:hover { transform: translateY(-5px); border-color: #FFB347; }
            .anime-card h3 { margin: 0; font-size: 1rem; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Camanime</h1>
            <form action="/search" method="get" class="search-box">
                <input type="text" name="q" placeholder="Search anime (e.g., One Piece, Naruto)" required>
                <button type="submit"><i class="fas fa-search"></i> Search</button>
            </form>

            <h3>Trending Now</h3>
            <div class="quick-links">
                <a href="/watch/21/1" class="anime-card"><h3>One Piece</h3></a>
                <a href="/watch/113415/1" class="anime-card"><h3>Jujutsu Kaisen</h3></a>
                <a href="/watch/16498/1" class="anime-card"><h3>Attack on Titan</h3></a>
                <a href="/watch/20/1" class="anime-card"><h3>Naruto</h3></a>
            </div>
        </div>
    </body>
    </html>
    """)

@app.route('/search')
def search():
    query = request.args.get('q')
    if not query:
        return redirect(url_for('index'))
    
    try:
        resp = requests.get(f"{CONSUMET_API}/meta/anilist/search?query={query}")
        data = resp.json()
        results = data.get('results', [])
        
        html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <title>Search Results</title>
            <style>
                body { font-family: sans-serif; background: #0a0c15; color: white; padding: 2rem; }
                .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 1.5rem; }
                .card { background: #1e263a; border-radius: 8px; overflow: hidden; text-decoration: none; color: white; transition: 0.2s; }
                .card:hover { transform: scale(1.03); }
                .card img { width: 100%; height: 250px; object-fit: cover; }
                .title { padding: 10px; font-weight: bold; font-size: 0.9rem; }
                h1 { color: #FFB347; }
            </style>
        </head>
        <body>
            <h1>Search Results for "{}"</h1>
            <div class="grid">
        """.format(query)
        
        for anime in results:
            title = anime.get('title', {}).get('romaji', 'Unknown')
            aid = anime['id']
            img = anime.get('image', 'https://placehold.co/200x300?text=No+Image')
            html += f"""
            <a href="/watch/{aid}/1" class="card">
                <img src="{img}" alt="{title}">
                <div class="title">{title}</div>
            </a>
            """
            
        html += "</div></body></html>"
        return html

    except Exception as e:
        return f"<h2>Error: {str(e)}</h2><a href='/'>Back</a>"

@app.route('/watch/<int:anime_id>/<int:episode>')
def watch(anime_id, episode):
    video_url, anime_title, episodes, is_iframe, error_msg = fetch_episode_sources(anime_id, episode)
    
    return render_template_string(WATCH_TEMPLATE,
                                  anime_title=anime_title,
                                  anime_id=anime_id,
                                  episode=episode,
                                  episodes=episodes,
                                  video_url=video_url,
                                  is_iframe=is_iframe,
                                  error_msg=error_msg)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)
