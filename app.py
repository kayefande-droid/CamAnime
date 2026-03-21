import cloudscraper
import re
import urllib.parse
from bs4 import BeautifulSoup
from flask import Flask, render_template, request, redirect, url_for, jsonify

app = Flask(__name__)

# --- CONFIGURATION ---
BASE_URL = "https://animeheaven.me"

# Initialize CloudScraper to bypass bot protection
scraper = cloudscraper.create_scraper(
    browser={
        'browser': 'chrome',
        'platform': 'windows',
        'desktop': True
    }
)

# --- SCRAPER FUNCTIONS (The "API" Logic) ---

def get_soup(url):
    """Fetches a URL and returns BeautifulSoup object."""
    try:
        resp = scraper.get(url, timeout=15)
        if resp.status_code == 200:
            return BeautifulSoup(resp.content, "html.parser")
        else:
            print(f"Failed to fetch {url}: {resp.status_code}")
    except Exception as e:
        print(f"Scraper Error ({url}): {e}")
    return None

def extract_id(url):
    """Extracts ID from AnimeHeaven URL."""
    if "?" in url:
        return url.split("?")[-1]
    return url.split("/")[-1]

def scrape_list(path):
    """Scrapes anime list (New/Popular)."""
    soup = get_soup(f"{BASE_URL}/{path}")
    results = []
    if soup:
        # AnimeHeaven class selectors
        items = soup.select(".c") 
        for item in items:
            link = item.select_one("a")
            img = item.select_one("img")
            title_tag = item.select_one(".t")
            ep_tag = item.select_one(".ep")
            
            if link and img:
                title = title_tag.get_text(strip=True) if title_tag else "Unknown"
                ep_text = ep_tag.get_text(strip=True) if ep_tag else "?"
                
                img_src = img.get('src', '')
                if img_src.startswith("//"): img_src = "https:" + img_src
                elif img_src.startswith("/"): img_src = BASE_URL + img_src
                
                href = link.get('href', '')
                anime_id = extract_id(href)
                
                results.append({
                    "id": anime_id,
                    "title": title,
                    "image": img_src,
                    "episode": ep_text
                })
    return results

def scrape_search_results(query):
    """Scrapes search results."""
    return scrape_list(f"search.php?q={urllib.parse.quote(query)}")

def scrape_anime_details(anime_id):
    """Scrapes anime info and episode list."""
    url = f"{BASE_URL}/anime.php?{anime_id}"
    soup = get_soup(url)
    
    if not soup:
        return None
        
    title = soup.select_one(".infotitle").get_text(strip=True) if soup.select_one(".infotitle") else "Unknown"
    desc = soup.select_one(".infodes").get_text(strip=True) if soup.select_one(".infodes") else ""
    img_tag = soup.select_one(".poster img")
    img_src = img_tag.get('src', '') if img_tag else ""
    if img_src.startswith("//"): img_src = "https:" + img_src
    elif img_src.startswith("/"): img_src = BASE_URL + img_src
    
    # Episodes
    episodes = []
    # Try multiple selectors for episode links
    links = soup.select(".d a") or soup.select(".episode a")
    
    for link in reversed(links):
        href = link.get('href', '')
        ep_num = link.get_text(strip=True)
        try:
            ep_id = extract_id(href)
            # Ensure we have a valid numeric display if possible
            num_match = re.search(r'\d+', ep_num)
            clean_num = num_match.group() if num_match else ep_num
            
            episodes.append({
                "id": ep_id,
                "num": clean_num,
                "url": href
            })
        except:
            pass
            
    return {
        "id": anime_id,
        "title": title,
        "description": desc,
        "image": img_src,
        "episodes": episodes
    }

def extract_video(ep_id):
    """
    Attempts to find the video embed URL.
    Falls back to vidsrc.cc if direct scraping fails.
    """
    # Construct URL. Sometimes ep_id is 'episode.php?id' sometimes just 'id'
    url = f"{BASE_URL}/episode.php?{ep_id}" if "episode.php" not in ep_id else f"{BASE_URL}/{ep_id}"
    soup = get_soup(url)
    stream_url = None
    
    if soup:
        # Strategy: Find iframe
        iframe = soup.select_one("iframe")
        if iframe:
            src = iframe.get('src', '')
            if src:
                if src.startswith("//"): src = "https:" + src
                stream_url = src

    # Fallback Logic (if scraper blocked)
    # Heuristic: try to guess anime ID and ep num from the ep_id string
    if not stream_url:
        # Common pattern: anime_id&ep=5
        # We need to extract the anime_id part for vidsrc
        # This is tricky because ep_id varies. 
        # Best fallback is simply to tell the user we couldn't find it.
        pass
        
    return stream_url

# --- ROUTES ---

@app.route('/')
def home():
    # Mimics /api/anime/popular + /api/anime/new-episodes
    # We'll scrape 'New' for the homepage
    trending = scrape_list("new.php")
    featured = trending[0] if trending else None
    return render_template('index.html', trending=trending, featured=featured, page_type="home")

@app.route('/search')
def search():
    query = request.args.get('q')
    if not query:
        return redirect(url_for('home'))
    results = scrape_search_results(query)
    return render_template('index.html', trending=results, search_query=query, page_type="search")

@app.route('/anime/<path:anime_id>')
def details(anime_id):
    anime = scrape_anime_details(anime_id)
    if not anime:
        return "Anime not found (Scraper might be blocked)", 404
    return render_template('details.html', anime=anime)

@app.route('/watch/<path:anime_id>/<path:ep_id>')
def watch(anime_id, ep_id):
    anime = scrape_anime_details(anime_id) # Need metadata
    
    stream_url = extract_video(ep_id)
    
    # If direct scrape fails, we try a fallback if we can parse the ID
    if not stream_url:
        # Try to construct a vidsrc link if the ID looks standard
        # Example ep_id: "episode.php?anime=123&ep=5" -> anime=123, ep=5
        try:
            match_id = re.search(r'anime=([^&]+)', ep_id)
            match_ep = re.search(r'ep=(\d+)', ep_id)
            if match_id and match_ep:
                aid = match_id.group(1)
                enum = match_ep.group(1)
                stream_url = f"https://vidsrc.cc/v2/embed/anime/{aid}/{enum}"
        except:
            pass

    return render_template('watch.html', 
                         anime=anime, 
                         ep_num=ep_id, 
                         stream_url=stream_url)

# --- API ENDPOINTS (Optional: If you want to use this as an API service too) ---
@app.route('/api/popular')
def api_popular():
    return jsonify(scrape_list("popular.php"))

@app.route('/api/search')
def api_search():
    return jsonify(scrape_search_results(request.args.get('q')))

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')