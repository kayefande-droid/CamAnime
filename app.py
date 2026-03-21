import requests
from flask import Flask, render_template, request, redirect, url_for, jsonify

app = Flask(__name__)

# --- CONFIGURATION ---
ANILIST_API_URL = 'https://graphql.anilist.co'
CONSUMET_API_URL = 'https://api.consumet.org/meta/anilist' 
# Alternative mirrors if the main one is down:
# https://api.consumet.org/meta/anilist
# https://consumet-api.herokuapp.com/meta/anilist

# --- GRAPHQL QUERIES (Keep these for fast metadata) ---
TRENDING_QUERY = '''
query ($page: Int, $perPage: Int) {
  Page (page: $page, perPage: $perPage) {
    media (sort: TRENDING_DESC, type: ANIME) {
      id
      title { romaji english }
      coverImage { large extraLarge }
      bannerImage
      episodes
      status
      format
      averageScore
      nextAiringEpisode { episode }
    }
  }
}
'''

SEARCH_QUERY = '''
query ($search: String, $page: Int, $perPage: Int) {
  Page (page: $page, perPage: $perPage) {
    media (search: $search, sort: POPULARITY_DESC, type: ANIME) {
      id
      title { romaji english }
      coverImage { large }
      episodes
      status
      averageScore
    }
  }
}
'''

DETAILS_QUERY = '''
query ($id: Int) {
  Media (id: $id, type: ANIME) {
    id
    title { romaji english }
    description
    coverImage { extraLarge }
    bannerImage
    episodes
    status
    format
    genres
    averageScore
    nextAiringEpisode { episode }
    recommendations(page: 1, perPage: 10) {
      nodes {
        mediaRecommendation {
          id
          title { romaji }
          coverImage { medium }
          averageScore
        }
      }
    }
  }
}
'''

def fetch_anilist(query, variables):
    """Helper to send requests to AniList API."""
    try:
        response = requests.post(ANILIST_API_URL, json={'query': query, 'variables': variables})
        return response.json().get('data', {})
    except Exception as e:
        print(f"AniList API Error: {e}")
        return {}

def get_consumet_stream(anime_id, episode_num):
    """
    Fetches the streaming link for a specific episode using Consumet API.
    1. Fetches episode list for the anime to find the specific episode ID.
    2. Fetches the stream sources for that episode ID.
    """
    try:
        # Step 1: Get episode list from Consumet (mapping AniList ID to provider IDs)
        # We use the AniList ID directly
        info_url = f"{CONSUMET_API_URL}/info/{anime_id}"
        resp = requests.get(info_url, timeout=5)
        
        if resp.status_code != 200:
            print(f"Consumet Info Error: {resp.status_code}")
            return None
            
        data = resp.json()
        episodes = data.get('episodes', [])
        
        # Find the matching episode object
        target_ep = next((ep for ep in episodes if ep.get('number') == episode_num), None)
        
        if not target_ep:
            print(f"Episode {episode_num} not found in Consumet data")
            return None
            
        episode_id = target_ep['id']
        
        # Step 2: Get streaming links
        watch_url = f"{CONSUMET_API_URL}/watch/{episode_id}"
        stream_resp = requests.get(watch_url, timeout=5)
        
        if stream_resp.status_code != 200:
            print(f"Consumet Watch Error: {stream_resp.status_code}")
            return None
            
        stream_data = stream_resp.json()
        
        # Prefer higher quality (default/auto is usually best for HLS)
        sources = stream_data.get('sources', [])
        if not sources:
            return None
            
        # Return the best source (usually the one with 'default' or 'backup')
        # We prefer m3u8 (HLS) for better streaming
        best_source = next((s for s in sources if s.get('quality') == 'default'), sources[0])
        return best_source.get('url')

    except Exception as e:
        print(f"Consumet API Exception: {e}")
        return None

@app.route('/')
def home():
    data = fetch_anilist(TRENDING_QUERY, {'page': 1, 'perPage': 20})
    trending = data.get('Page', {}).get('media', [])
    featured = trending[0] if trending else None
    return render_template('index.html', trending=trending, featured=featured, page_type="home")

@app.route('/search')
def search():
    query = request.args.get('q')
    if not query:
        return redirect(url_for('home'))
    data = fetch_anilist(SEARCH_QUERY, {'search': query, 'page': 1, 'perPage': 24})
    results = data.get('Page', {}).get('media', [])
    return render_template('index.html', trending=results, search_query=query, page_type="search")

@app.route('/anime/<int:anime_id>')
def details(anime_id):
    data = fetch_anilist(DETAILS_QUERY, {'id': anime_id})
    anime = data.get('Media')
    if not anime:
        return "Anime not found", 404

    # Logic to determine max episodes
    total_episodes = anime.get('episodes') or 0
    if anime.get('status') == 'RELEASING' and anime.get('nextAiringEpisode'):
        total_episodes = anime['nextAiringEpisode']['episode'] - 1
    elif total_episodes == 0:
         total_episodes = 100 # Fallback
    
    episode_list = list(range(1, total_episodes + 1))
    episode_list.reverse()

    return render_template('details.html', anime=anime, episode_list=episode_list)

@app.route('/watch/<int:anime_id>/<int:ep_num>')
def watch(anime_id, ep_num):
    data = fetch_anilist(DETAILS_QUERY, {'id': anime_id})
    anime = data.get('Media')
    
    if not anime:
        return "Anime not found", 404

    # Fetch real stream URL
    stream_url = get_consumet_stream(anime_id, ep_num)
    
    # Fallback to embedded players if API fetch fails or is slow
    # This ensures user always sees SOMETHING
    backup_embed = f"https://vidsrc.cc/v2/embed/anime/{anime_id}/{ep_num}"
    
    total_episodes = anime.get('episodes') or 100
    if anime.get('nextAiringEpisode'):
        total_episodes = anime['nextAiringEpisode']['episode'] - 1
        
    prev_ep = ep_num - 1 if ep_num > 1 else None
    next_ep = ep_num + 1 if ep_num < total_episodes else None

    return render_template('watch.html', 
                         anime=anime, 
                         ep_num=ep_num, 
                         stream_url=stream_url,
                         backup_embed=backup_embed,
                         prev_ep=prev_ep, 
                         next_ep=next_ep)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')