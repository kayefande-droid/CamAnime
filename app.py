import cloudscraper
import re
import urllib.parse
from bs4 import BeautifulSoup
from flask import Flask, render_template, request, redirect, url_for

app = Flask(__name__)

# --- CONFIGURATION ---
BASE_URL = "https://animeheaven.me"

# Initialize CloudScraper (bypasses Cloudflare)
scraper = cloudscraper.create_scraper(
    browser={
        'browser': 'chrome',
        'platform': 'windows',
        'desktop': True
    }
)

# --- HELPER FUNCTIONS ---

def get_soup(url):
    """Fetches a URL using CloudScraper and returns BeautifulSoup."""
    try:
        # Cloudscraper handles cookies and headers automatically
        resp = scraper.get(url, timeout=15)
        if resp.status_code == 200:
            return BeautifulSoup(resp.content, "html.parser")
        else:
            print(f"Failed to fetch {url}: Status {resp.status_code}")
    except Exception as e:
        print(f"Scraper Error ({url}): {e}")
    return None

def extract_anime_id(url):
    """Extracts ID from URL like /anime.php?id=123."""
    if "?" in url:
        return url.split("?")[-1]
    return url.split("/")[-1]

# --- SCRAPER LOGIC ---

def scrape_home():
    """Scrapes the homepage for Trending/New anime."""
    soup = get_soup(f"{BASE_URL}")
    anime_list = []
    
    if soup:
        # Updated selector logic based on standard AH structure
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
                anime_id = extract_anime_id(href)

                anime_list.append({
                    "id": anime_id,
                    "title": title,
                    "image": img_src,
                    "episode": ep_text,
                    "url": href
                })
    return anime_list

def scrape_search(query):
    """Scrapes search results."""
    soup = get_soup(f"{BASE_URL}/search.php?q={urllib.parse.quote(query)}")
    results = []
    
    if soup:
        items = soup.select(".c")
        for item in items:
            link = item.select_one("a")
            img = item.select_one("img")
            title_tag = item.select_one(".t")
            
            if link and img:
                title = title_tag.get_text(strip=True) if title_tag else "Unknown"
                img_src = img.get('src', '')
                if img_src.startswith("//"): img_src = "https:" + img_src
                elif img_src.startswith("/"): img_src = BASE_URL + img_src
                
                href = link.get('href', '')
                anime_id = extract_anime_id(href)
                
                results.append({
                    "id": anime_id,
                    "title": title,
                    "image": img_src,
                    "episode": "?",
                    "url": href
                })
    return results

def scrape_details(anime_id):
    """Scrapes anime details and episode list."""
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
    
    # Get Episodes
    episodes = []
    # Try different selectors for episodes as layouts vary
    ep_links = soup.select(".d a") or soup.select(".episode a")
    
    for link in reversed(ep_links):
        ep_url = link.get('href', '')
        ep_num = link.get_text(strip=True)
        try:
            # Extract episode ID (e.g., episode.php?anime_id&ep=1)
            ep_id = ep_url.split("?")[-1] if "?" in ep_url else ep_url
            episodes.append({
                "num": ep_num,
                "id": ep_id,
                "url": ep_url
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

def extract_stream_url(anime_id, ep_id):
    """
    Attempts to extract the video embed URL.
    Falls back to vidsrc.cc if direct scraping fails.
    """
    url = f"{BASE_URL}/episode.php?{ep_id}"
    soup = get_soup(url)
    
    stream_url = None
    
    if soup:
        # Try to find the iframe directly
        iframe = soup.select_one("iframe")
        if iframe:
            src = iframe.get('src', '')
            if src:
                if src.startswith("//"): src = "https:" + src
                # Filter out ads or junk iframes
                if "google" in src or "vid" in src or "mp4" in src:
                    stream_url = src

    # Reliable Fallback: Construct vidsrc.cc embed
    # We need the numeric episode number for the fallback
    # The ep_id often looks like 'anime_id&ep=1' or similar
    try:
        if not stream_url:
            # Try to parse the episode number from the ID string if possible
            # This is a heuristic guess
            match = re.search(r'ep=(\d+)', ep_id)
            if match:
                ep_num = match.group(1)
                stream_url = f"https://vidsrc.cc/v2/embed/anime/{anime_id}/{ep_num}"
            else:
                # Last ditch: just use the ep_id if it looks like a number
                if ep_id.isdigit():
                    stream_url = f"https://vidsrc.cc/v2/embed/anime/{anime_id}/{ep_id}"
    except:
        pass
        
    return stream_url

# --- ROUTES ---

@app.route('/')
def home():
    trending = scrape_home()
    featured = trending[0] if trending else None
    return render_template('index.html', trending=trending, featured=featured, page_type="home")

@app.route('/search')
def search():
    query = request.args.get('q')
    if not query:
        return redirect(url_for('home'))
    results = scrape_search(query)
    return render_template('index.html', trending=results, search_query=query, page_type="search")

@app.route('/anime/<path:anime_id>')
def details(anime_id):
    anime = scrape_details(anime_id)
    if not anime:
        return "Anime not found", 404
    return render_template('details.html', anime=anime)

@app.route('/watch/<path:anime_id>/<path:ep_id>')
def watch(anime_id, ep_id):
    anime = scrape_details(anime_id)
    stream_url = extract_stream_url(anime_id, ep_id)
    
    if not stream_url:
        stream_url = f"https://vidsrc.cc/v2/embed/anime/{anime_id}/{ep_id}"

    prev_ep = None
    next_ep = None
    display_num = ep_id
    
    if anime and anime.get('episodes'):
        eps = anime['episodes']
        for i, ep in enumerate(eps):
            if ep['id'] == ep_id:
                display_num = ep['num']
                if i > 0:
                    next_ep = eps[i-1] # Episodes are reversed in list
                if i < len(eps) - 1:
                    prev_ep = eps[i+1]
                break

    return render_template('watch.html', 
                         anime=anime, 
                         ep_num=display_num, 
                         stream_url=stream_url,
                         prev_ep=prev_ep,
                         next_ep=next_ep)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')