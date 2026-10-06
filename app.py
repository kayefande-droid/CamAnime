import requests
import logging
import re

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

from flask import Flask, render_template, request, redirect, url_for
from streaming_providers import streaming_manager

app = Flask(__name__)

# --- CONFIGURATION ---
ANILIST_API_URL = 'https://graphql.anilist.co'
CONSUMET_API_URL = 'https://api.consumet.org/meta/anilist' 

# --- GRAPHQL QUERIES ---
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
      coverImage { large extraLarge }
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
  }
}
'''

def fetch_anilist(query, variables):
    """Fetches data from AniList GraphQL API."""
    try:
        response = requests.post(ANILIST_API_URL, json={'query': query, 'variables': variables})
        response.raise_for_status()  # Raise an exception for bad status codes
        return response.json().get('data', {})
    except requests.exceptions.RequestException as e:
        logger.error(f"AniList API Error: {e}")
        return {}
    except ValueError as e:  # JSON decode error
        logger.error(f"AniList JSON Decode Error: {e}")
        return {}


@app.route('/')
def home():
    data = fetch_anilist(TRENDING_QUERY, {'page': 1, 'perPage': 20})
    trending = data.get('Page', {}).get('media', [])
    featured = trending[0] if trending else None
    
    # Process data for template
    processed_trending = []
    for anime in trending:
        # Use extraLarge if available, otherwise fall back to large
        cover_image = anime['coverImage']
        image_url = cover_image.get('extraLarge') or cover_image.get('large')
        processed_trending.append({
            "id": anime['id'],
            "title": anime['title']['english'] or anime['title']['romaji'],
            "image": image_url,
            "episode": f"Ep {anime.get('nextAiringEpisode', {}).get('episode', 0) - 1}" if anime.get('nextAiringEpisode') else f"{anime.get('episodes')} Eps"
        })
        
    processed_featured = None
    if featured:
        processed_featured = {
            "id": featured['id'],
            "title": featured['title']['english'] or featured['title']['romaji'],
            "image": featured['bannerImage'] or featured['coverImage']['extraLarge'],
            "format": featured['format'],
            "episode": f"Ep {featured.get('nextAiringEpisode', {}).get('episode', 0) - 1}" if featured.get('nextAiringEpisode') else f"{featured.get('episodes')} Eps"
        }

    return render_template('index.html', trending=processed_trending, featured=processed_featured, page_type="home")

@app.route('/search')
def search():
    query = request.args.get('q')
    if not query:
        return redirect(url_for('home'))
        
    data = fetch_anilist(SEARCH_QUERY, {'search': query, 'page': 1, 'perPage': 24})
    raw_results = data.get('Page', {}).get('media', [])
    
    results = []
    for anime in raw_results:
        # Use extraLarge if available, otherwise fall back to large
        cover_image = anime['coverImage']
        image_url = cover_image.get('extraLarge') or cover_image.get('large')

        results.append({
            "id": anime['id'],
            "title": anime['title']['english'] or anime['title']['romaji'],
            "image": image_url,
            "episode": f"{anime.get('episodes') or '?'} Eps"
        })
        
    return render_template('index.html', trending=results, search_query=query, page_type="search")

@app.route('/anime/<int:anime_id>')
def details(anime_id):
    data = fetch_anilist(DETAILS_QUERY, {'id': anime_id})
    raw_anime = data.get('Media')
    
    if not raw_anime:
        return "Anime not found", 404

    # Calculate episodes
    total_episodes = raw_anime.get('episodes') or 0
    if raw_anime.get('status') == 'RELEASING' and raw_anime.get('nextAiringEpisode'):
        total_episodes = raw_anime['nextAiringEpisode']['episode'] - 1
    elif total_episodes == 0:
         total_episodes = None  # Unknown episode count
    
    episode_list = []
    if total_episodes is not None:
        for i in range(1, total_episodes + 1):
            episode_list.append({"id": i, "num": i})
        episode_list.reverse()
    else:
        # If episode count is unknown, show a reasonable default or leave empty
        # For now, we'll show first 20 episodes as placeholder
        for i in range(1, 21):
            episode_list.append({"id": i, "num": i})
        episode_list.reverse()

    anime = {
        "id": raw_anime['id'],
        "title": raw_anime['title']['english'] or raw_anime['title']['romaji'],
        "description": raw_anime['description'],
        "image": raw_anime['coverImage']['extraLarge'],
        "rating": raw_anime['averageScore'] / 10 if raw_anime.get('averageScore') else "N/A",
        "tags": raw_anime['genres'],
        "format": raw_anime['format'],
        "status": raw_anime['status'],
        "episodes": episode_list
    }

    return render_template('details.html', anime=anime)

@app.route('/watch/<int:anime_id>/<int:ep_num>')
def watch(anime_id, ep_num):
    data = fetch_anilist(DETAILS_QUERY, {'id': anime_id})
    raw_anime = data.get('Media')
    
    anime_title = "Unknown Anime"
    if raw_anime:
        anime_title = raw_anime['title']['english'] or raw_anime['title']['romaji']
    
    # Get streaming sources using our manager with fallback
    # Try to get streaming sources from any available provider
    streaming_result = streaming_manager.get_streaming_sources(str(anime_id), provider=None)

    # Extract the best available stream URL
    stream_url = None
    if streaming_result.get('sources') and len(streaming_result['sources']) > 0:
        # Use the first available source
        stream_url = streaming_result['sources'][0].get('url')

    # Fallback Embed
    backup_embed = f"https://vidsrc.cc/v2/embed/anime/{anime_id}/{ep_num}"

    return render_template('watch.html', 
                         anime={"id": anime_id, "title": anime_title, "bannerImage": raw_anime.get('bannerImage') if raw_anime else ""}, 
                         ep_num=ep_num, 
                         stream_url=stream_url,
                         backup_embed=backup_embed,
                         prev_ep=ep_num - 1 if ep_num > 1 else None, 
                         next_ep=ep_num + 1)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')