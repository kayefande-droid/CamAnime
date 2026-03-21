import requests
from flask import Flask, render_template, request, redirect, url_for

app = Flask(__name__)

# --- CONFIGURATION ---
ANILIST_API_URL = 'https://graphql.anilist.co'

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
      nextAiringEpisode { episode timeUntilAiring }
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
        print(f"API Error: {e}")
        return {}

@app.route('/')
def home():
    # Fetch Trending Anime (serves as "New/Popular")
    data = fetch_anilist(TRENDING_QUERY, {'page': 1, 'perPage': 20})
    trending = data.get('Page', {}).get('media', [])
    
    # Pick the top item as the "Featured" hero anime
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

    # Calculate available episodes
    # If ongoing, nextAiringEpisode tells us the current max. 
    # If finished, use 'episodes'.
    total_episodes = anime.get('episodes') or 0
    if anime.get('status') == 'RELEASING' and anime.get('nextAiringEpisode'):
        total_episodes = anime['nextAiringEpisode']['episode'] - 1
    elif total_episodes == 0:
         # Fallback for long runners with unknown count
         total_episodes = 1000 
    
    # Generate list of episodes
    episode_list = list(range(1, total_episodes + 1))
    episode_list.reverse() # Show newest first

    return render_template('details.html', anime=anime, episode_list=episode_list)

@app.route('/watch/<int:anime_id>/<int:ep_num>')
def watch(anime_id, ep_num):
    data = fetch_anilist(DETAILS_QUERY, {'id': anime_id})
    anime = data.get('Media')
    
    if not anime:
        return "Anime not found", 404

    # Primary Embed Source (vidsrc.cc uses AniList ID)
    stream_url = f"https://vidsrc.cc/v2/embed/anime/{anime_id}/{ep_num}"
    
    # Generate simple next/prev links
    total_episodes = anime.get('episodes') or 1000
    if anime.get('nextAiringEpisode'):
        total_episodes = anime['nextAiringEpisode']['episode'] - 1
        
    prev_ep = ep_num - 1 if ep_num > 1 else None
    next_ep = ep_num + 1 if ep_num < total_episodes else None

    return render_template('watch.html', 
                         anime=anime, 
                         ep_num=ep_num, 
                         stream_url=stream_url,
                         prev_ep=prev_ep, 
                         next_ep=next_ep)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')