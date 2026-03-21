import requests
import re
import json
import urllib.parse
from bs4 import BeautifulSoup
from flask import Flask, render_template, request, redirect, url_for

app = Flask(__name__)

# --- CONFIGURATION ---
BASE_URL = "https://animeheaven.me"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36",
    "Referer": "https://animeheaven.me/",
    "Origin": "https://animeheaven.me"
}

# --- HELPER FUNCTIONS ---

def get_soup(url):
    """Fetches a URL and returns a BeautifulSoup object."""
    try:
        resp = requests.get(url, headers=HEADERS, timeout=10)
        if resp.status_code == 200:
            return BeautifulSoup(resp.content, "html.parser")
    except Exception as e:
        print(f"Request Error ({url}): {e}")
    return None

def extract_anime_id(url):
    """Extracts ID from URL like /anime.php?id=123 or /anime/123."""
    if "?" in url:
        return url.split("?")[-1]
    return url.split("/")[-1]

# --- SCRAPER LOGIC ---

def scrape_home():
    """Scrapes the homepage for Trending/New anime."""
    soup = get_soup(f"{BASE_URL}")
    anime_list = []
    
    if soup:
        # Select anime grid items (adjust selector based on actual site structure)
        # Typically .c or .iep for grid items
        items = soup.select(".c") 
        for item in items:
            link = item.select_one("a")
            img = item.select_one("img")
            title_tag = item.select_one(".t") # title class
            ep_tag = item.select_one(".ep")   # episode count class
            
            if link and img:
                title = title_tag.get_text(strip=True) if title_tag else "Unknown"
                ep_text = ep_tag.get_text(strip=True) if ep_tag else "?"
                
                # Fix relative URLs
                img_src = img['src']
                if img_src.startswith("//"): img_src = "https:" + img_src
                elif img_src.startswith("/"): img_src = BASE_URL + img_src
                
                href = link['href']
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
                img_src = img['src']
                if img_src.startswith("//"): img_src = "https:" + img_src
                
                href = link['href']
                anime_id = extract_anime_id(href)
                
                results.append({
                    "id": anime_id,
                    "title": title,
                    "image": img_src,
                    "episode": "?", # Search results might not show ep count
                    "url": href
                })
    return results

def scrape_details(anime_id):
    """Scrapes anime details and episode list."""
    url = f"{BASE_URL}/anime.php?{anime_id}" # Typical AH pattern
    soup = get_soup(url)
    
    if not soup:
        return None
        
    title = soup.select_one(".infotitle").get_text(strip=True) if soup.select_one(".infotitle") else "Unknown"
    desc = soup.select_one(".infodes").get_text(strip=True) if soup.select_one(".infodes") else ""
    img = soup.select_one(".poster img")
    img_src = img['src'] if img else ""
    if img_src.startswith("//"): img_src = "https:" + img_src
    
    # Get Episodes
    episodes = []
    # Episodes are usually links in a grid, e.g. .d a
    ep_links = soup.select(".d a") 
    for link in reversed(ep_links): # Newest first usually
        ep_url = link['href']
        ep_num = link.get_text(strip=True)
        # Often just "1", "2", etc.
        try:
            ep_id = extract_anime_id(ep_url)
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
    Attempts to extract the video URL from the episode page.
    This is the hardest part. AH usually embeds a player.
    """
    # 1. Get episode page
    url = f"{BASE_URL}/{ep_id}" if "php" in ep_id else f"{BASE_URL}/episode.php?{ep_id}"
    soup = get_soup(url)
    
    stream_url = None
    backup_embed = None
    
    if soup:
        # Strategy 1: Look for IFRAME (Embed)
        # Often id='video' or class='player'
        iframe = soup.select_one("iframe")
        if iframe:
            src = iframe['src']
            if src.startswith("//"): src = "https:" + src
            # This is likely a VidCloud/Gogo/StreamTape embed
            backup_embed = src
            
        # Strategy 2: Look for direct script injection (p, packed JS)
        # This requires JS execution which we can't do easily in pure Python.
        # However, we can use a known consistent fallback like vidsrc.cc based on ID.
        
        # If we found a specific embed URL (e.g. from Gogoanime), use it.
        # Otherwise, construct a fallback.
        
    # Since direct extraction of the 'm3u8' is very hard without Selenium/Node,
    # we will return the embed URL found, or a constructed fallback.
    
    # Construct fallback based on knowledge of other APIs
    if not backup_embed:
        # Fallback to vidsrc.cc using the anime ID + episode number if possible
        # We need the numeric episode number for this.
        # For now, let's just use the iframe found or None.
        pass
        
    return backup_embed

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
    anime = scrape_details(anime_id) # Need metadata
    
    # Get the actual stream URL from the episode page
    stream_url = extract_stream_url(anime_id, ep_id)
    
    # If scraper fails to find an iframe, use a generic fallback
    # (This assumes standard ID format, might need adjustment)
    if not stream_url:
        stream_url = f"https://vidsrc.cc/v2/embed/anime/{anime_id}/{ep_id}"

    # Find prev/next
    prev_ep = None
    next_ep = None
    # (Simple logic: find current in list and get neighbors)
    
    return render_template('watch.html', 
                         anime=anime, 
                         ep_num=ep_id, 
                         stream_url=stream_url,
                         backup_embed=stream_url)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')