"""
CamAnime Streaming Providers Module
Multi-source streaming integration with caching and fallback support
"""

import requests
import json
import logging
import re
from typing import List, Dict, Optional, Tuple
from functools import lru_cache
import time
from bs4 import BeautifulSoup

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class StreamingProvider:
    """Base streaming provider class"""

    def __init__(self, timeout=10):
        self.timeout = timeout
        self.cache = {}
        self.cache_duration = 3600  # 1 hour

    def search(self, query: str) -> List[Dict]:
        """Search for anime"""
        raise NotImplementedError

    def get_episodes(self, anime_id: str) -> List[Dict]:
        """Get episodes for anime"""
        raise NotImplementedError

    def get_streaming_sources(self, episode_id: str) -> Dict:
        """Get streaming sources for episode"""
        raise NotImplementedError

    def _cache_get(self, key: str) -> Optional[Dict]:
        """Get cached value if not expired"""
        if key in self.cache:
            data, timestamp = self.cache[key]
            if time.time() - timestamp < self.cache_duration:
                return data
        return None

    def _cache_set(self, key: str, value: Dict):
        """Cache a value"""
        self.cache[key] = (value, time.time())


class ConsumetProvider(StreamingProvider):
    """Consumet.org API provider (GoGoAnime, Zoro)"""

    def __init__(self, provider_type='gogoanime', timeout=10):
        super().__init__(timeout)
        self.base_url = 'https://api.consumet.org'
        self.provider_type = provider_type  # 'gogoanime' or 'zoro'

    def search(self, query: str) -> List[Dict]:
        """Search anime on Consumet"""
        cache_key = f"consumet_search_{self.provider_type}_{query}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached

        try:
            url = f"{self.base_url}/anime/{self.provider_type}/search"
            params = {'query': query}
            response = requests.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()

            data = response.json()
            results = data.get('results', [])

            self._cache_set(cache_key, results)
            return results

        except Exception as e:
            logger.error(f"Consumet search error ({self.provider_type}): {e}")
            return []

    def get_episodes(self, anime_id: str) -> Tuple[List[Dict], str]:
        """Get episodes for anime"""
        cache_key = f"consumet_episodes_{self.provider_type}_{anime_id}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached, "cached"

        try:
            url = f"{self.base_url}/anime/{self.provider_type}/info"
            params = {'id': anime_id}
            response = requests.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()

            data = response.json()
            episodes = data.get('episodes', [])
            title = data.get('title', 'Unknown')

            result = (episodes, title)
            self._cache_set(cache_key, result)
            return result, "fresh"

        except Exception as e:
            logger.error(f"Consumet episodes error ({self.provider_type}): {e}")
            return ([], "Unknown"), "error"

    def get_streaming_sources(self, episode_id: str) -> Dict:
        """Get streaming sources for episode"""
        cache_key = f"consumet_sources_{self.provider_type}_{episode_id}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached

        try:
            url = f"{self.base_url}/anime/{self.provider_type}/watch"
            params = {'id': episode_id}
            response = requests.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()

            data = response.json()

            # Format response
            result = {
                'sources': self._format_sources(data.get('sources', [])),
                'subtitles': self._format_subtitles(data.get('subtitles', [])),
                'provider': self.provider_type,
                'episode_id': episode_id
            }

            self._cache_set(cache_key, result)
            return result

        except Exception as e:
            logger.error(f"Consumet streaming error ({self.provider_type}): {e}")
            return {'sources': [], 'subtitles': [], 'provider': self.provider_type, 'error': str(e)}

    def _format_sources(self, sources: List[Dict]) -> List[Dict]:
        """Format streaming sources"""
        formatted = []
        for source in sources:
            formatted.append({
                'url': source.get('url', ''),
                'quality': source.get('quality', 'default'),
                'isM3u8': '.m3u8' in source.get('url', '').lower()
            })
        return formatted

    def _format_subtitles(self, subtitles: List[Dict]) -> List[Dict]:
        """Format subtitles"""
        formatted = []
        for sub in subtitles:
            formatted.append({
                'url': sub.get('url', ''),
                'lang': sub.get('lang', 'Unknown'),
                'kind': 'subtitles'
            })
        return formatted

    def get_trending(self) -> List[Dict]:
        """Get trending anime"""
        cache_key = f"consumet_trending_{self.provider_type}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached

        try:
            url = f"{self.base_url}/anime/{self.provider_type}/recent-episodes"
            response = requests.get(url, timeout=self.timeout)
            response.raise_for_status()

            data = response.json()
            results = data.get('results', [])

            self._cache_set(cache_key, results)
            return results

        except Exception as e:
            logger.error(f"Consumet trending error ({self.provider_type}): {e}")
            return []


class MiruroProvider(StreamingProvider):
    """MiruroAPI provider for anime streaming"""

    def __init__(self, timeout=10):
        super().__init__(timeout)
        self.base_url = 'https://mirurotvapi.vercel.app/api'

    def search(self, query: str) -> List[Dict]:
        """Search anime on MiruroAPI"""
        cache_key = f"miruro_search_{query}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached

        try:
            url = f"{self.base_url}/search"
            params = {'query': query, 'page': 1, 'per_page': 20}
            response = requests.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()

            data = response.json()
            if data.get('success'):
                results = data.get('results', {}).get('results', [])

                # Format results to match expected structure
                formatted_results = []
                for anime in results:
                    formatted_results.append({
                        'id': str(anime.get('id')),
                        'title': anime.get('title', {}).get('english') or anime.get('title', {}).get('romaji', 'Unknown'),
                        'image': anime.get('coverImage', {}).get('large'),
                        'episodes': anime.get('episodes'),
                        'status': anime.get('status'),
                        'score': anime.get('averageScore')
                    })

                self._cache_set(cache_key, formatted_results)
                return formatted_results
            return []

        except Exception as e:
            logger.error(f"MiruroAPI search error: {e}")
            return []

    def get_episodes(self, anime_id: str) -> Tuple[List[Dict], str]:
        """Get episodes for anime from MiruroAPI"""
        cache_key = f"miruro_episodes_{anime_id}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached, "cached"

        try:
            url = f"{self.base_url}/episodes/{anime_id}"
            response = requests.get(url, timeout=self.timeout)
            response.raise_for_status()

            data = response.json()
            if not data.get('success'):
                return ([], "Unknown"), "error"

            # MiruroAPI episodes endpoint returns provider-specific watch data
            # We need to extract episode information from this
            episodes_data = data.get('results', [])

            # Build episode list from the provider data
            episodes = []
            title = "Unknown"

            # The data structure appears to be a list of watch options from different providers
            # We'll extract unique episode numbers from this data
            episode_numbers = set()

            for item in episodes_data:
                # Extract title if available
                if 'title' in item and (not title or title == "Unknown"):
                    title_info = item.get('title', {})
                    title = title_info.get('english') or title_info.get('romaji', 'Unknown')

                # Extract episode info from the watch path or similar
                # The structure might vary, so we'll try to get episode number
                episode_num = item.get('episode') or item.get('number')
                if episode_num:
                    episode_numbers.add(int(episode_num))

            # Create episode list sorted by episode number
            for ep_num in sorted(episode_numbers):
                episodes.append({
                    "id": ep_num,
                    "num": ep_num,
                    "title": f"Episode {ep_num}"
                })

            # If we didn't get specific episode numbers, try to get from a generic info endpoint
            if not episodes:
                # Fallback: try to get anime info to get episode count
                info_url = f"{self.base_url}/info/{anime_id}"
                info_response = requests.get(info_url, timeout=self.timeout)
                if info_response.status_code == 200:
                    info_data = info_response.json()
                    if info_data.get('success'):
                        info_results = info_data.get('results', {})
                        total_episodes = info_results.get('episodes', 0)
                        if total_episodes > 0:
                            for ep_num in range(1, total_episodes + 1):
                                episodes.append({
                                    "id": ep_num,
                                    "num": ep_num,
                                    "title": f"Episode {ep_num}"
                                })
                            # Try to get title from info
                            title_info = info_results.get('title', {})
                            title = title_info.get('english') or title_info.get('romaji', 'Unknown')

            result = (episodes, title)
            self._cache_set(cache_key, result)
            return result, "fresh"

        except Exception as e:
            logger.error(f"MiruroAPI episodes error: {e}")
            return ([], "Unknown"), "error"

    def get_streaming_sources(self, episode_id: str) -> Dict:
        """Get streaming sources for episode from MiruroAPI"""
        # For MiruroAPI, we need to first get episodes to get the watch path,
        # then use that to get streaming sources
        # This is a bit complex, so let's try a simpler approach

        cache_key = f"miruro_sources_{episode_id}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached

        try:
            # Try the watch endpoint directly - we need to figure out the format
            # Based on documentation: /watch/:provider/:anilistId/:category/:slug
            # But we don't have provider/category/slug from just episode_id

            # Alternative: try to get from embed endpoint
            embed_url = f"{self.base_url}/embed/{episode_id}/1"  # Assuming episode 1
            embed_response = requests.get(embed_url, timeout=self.timeout)

            if embed_response.status_code == 200:
                embed_data = embed_response.json()
                if embed_data.get('success'):
                    embed_results = embed_data.get('results', {})
                    stream_url = embed_results.get('url') or embed_results.get('streamUrl')

                    if stream_url:
                        result = {
                            'sources': [{
                                'url': stream_url,
                                'quality': 'default',
                                'isM3u8': '.m3u8' in stream_url.lower()
                            }],
                            'subtitles': [],  # MiruroAPI might not separate subtitles in this endpoint
                            'provider': 'miruro'
                        }
                        self._cache_set(cache_key, result)
                        return result

            # If embed doesn't work, let's try to get episodes first to get watch info
            episodes_result, _ = self.get_episodes(episode_id)
            if episodes_result and len(episodes_result) > 0:
                # We need to get the watch path from the episodes data
                # This requires calling the episodes endpoint again to get the full data
                url = f"{self.base_url}/episodes/{episode_id}"
                response = requests.get(url, timeout=self.timeout)
                if response.status_code == 200:
                    data = response.json()
                    if data.get('success'):
                        results = data.get('results', [])
                        if results and len(results) > 0:
                            # Take the first available source
                            first_result = results[0]
                            # The result should contain information to build the watch URL
                            # This is speculative - we may need to adjust based on actual API response
                            watch_path = first_result.get('watchPath') or first_result.get('path')
                            if watch_path:
                                watch_url = f"{self.base_url}{watch_path}"
                                watch_response = requests.get(watch_url, timeout=self.timeout)
                                if watch_response.status_code == 200:
                                    watch_data = watch_response.json()
                                    if watch_data.get('success'):
                                        streams = watch_data.get('results', {}).get('streams', [])
                                        formatted_sources = []
                                        for stream in streams:
                                            stream_url = stream.get('url')
                                            if stream_url:
                                                formatted_sources.append({
                                                    'url': stream_url,
                                                    'quality': stream.get('quality', 'default'),
                                                    'isM3u8': '.m3u8' in stream_url.lower()
                                                })

                                        if formatted_sources:
                                            result = {
                                                'sources': formatted_sources,
                                                'subtitles': [],  # Would need to extract from watch_data
                                                'provider': 'miruro'
                                            }
                                            self._cache_set(cache_key, result)
                                            return result

            # If all else fails, return empty
            return {'sources': [], 'subtitles': [], 'provider': 'miruro', 'error': 'No streaming sources found'}

        except Exception as e:
            logger.error(f"MiruroAPI streaming error: {e}")
            return {'sources': [], 'subtitles': [], 'provider': 'miruro', 'error': str(e)}


class AnimeHeavenProvider(StreamingProvider):
    """AnimeHeaven provider for anime streaming"""

    def __init__(self, timeout=10):
        super().__init__(timeout)
        self.base_url = 'https://animeheaven.me'
        # Alternative domains if the main one is blocked
        self.alternative_domains = [
            'https://animeheaven.ru',
            'https://animeheaven.app',
            'https://animeheaven.pro'
        ]

    def _make_request(self, url: str, params: dict = None) -> Optional[requests.Response]:
        """Make HTTP request with fallback to alternative domains"""
        domains_to_try = [self.base_url] + self.alternative_domains

        for domain in domains_to_try:
            try:
                # Replace the base URL in the request URL
                request_url = url.replace(self.base_url, domain)
                response = requests.get(request_url, params=params, timeout=self.timeout)
                response.raise_for_status()
                return response
            except Exception as e:
                logger.debug(f"Failed to connect to {domain}: {e}")
                continue

        logger.error(f"All domains failed for URL: {url}")
        return None

    def search(self, query: str) -> List[Dict]:
        """Search anime on AnimeHeaven"""
        cache_key = f"animeheaven_search_{query}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached

        try:
            # AnimeHeaven likely uses a search endpoint or we need to scrape the search page
            # Let's try a common search pattern
            url = f"{self.base_url}/search"
            params = {'keyword': query}

            response = self._make_request(url, params)
            if not response:
                return []

            # Parse HTML response
            soup = BeautifulSoup(response.content, 'html.parser')

            # Find anime results - this will need to be adjusted based on actual site structure
            results = []

            # Look for common patterns in anime listing sites
            anime_items = soup.find_all('div', class_=['anime-item', 'movie-item', 'item', 'post'])
            if not anime_items:
                # Try alternative selectors
                anime_items = soup.find_all('li', class_=['anime', 'movie'])
            if not anime_items:
                # Try finding by common attributes
                anime_items = soup.find_all('a', href=re.compile(r'/anime/|/watch/|/title/'))

            for item in anime_items[:20]:  # Limit to 20 results
                try:
                    # Extract title
                    title_elem = item.find(['h3', 'h2', 'h4', 'a'], class_=re.compile(r'title|name'))
                    if not title_elem:
                        title_elem = item.find('a')

                    title = title_elem.get_text(strip=True) if title_elem else 'Unknown'

                    # Extract URL/id
                    link_elem = item.find('a', href=True)
                    anime_id = ''
                    if link_elem:
                        href = link_elem.get('href', '')
                        # Extract ID from URL
                        id_match = re.search(r'/anime/(\d+)', href) or re.search(r'/title/(\d+)', href) or re.search(r'/watch/(\d+)', href)
                        if id_match:
                            anime_id = id_match.group(1)
                        else:
                            # Use the full path as ID if no numeric ID found
                            anime_id = href.split('/')[-1] if href.split('/')[-1] else href

                    # Extract image
                    img_elem = item.find('img')
                    image_url = img_elem.get('src') or img_elem.get('data-src') if img_elem else ''

                    # Extract episodes info if available
                    episodes_elem = item.find(text=re.compile(r'\d+\s*eps|\d+\s*episode', re.I))
                    episodes = None
                    if episodes_elem:
                        ep_match = re.search(r'(\d+)', episodes_elem)
                        if ep_match:
                            episodes = int(ep_match.group(1))

                    if title and title != 'Unknown':
                        results.append({
                            'id': anime_id or str(hash(title)),  # Fallback ID
                            'title': title,
                            'image': image_url,
                            'episodes': episodes,
                            'status': 'Unknown',  # Would need to extract from page
                            'score': 0  # Would need to extract from page
                        })
                except Exception as e:
                    logger.debug(f"Error parsing anime item: {e}")
                    continue

            self._cache_set(cache_key, results)
            return results

        except Exception as e:
            logger.error(f"AnimeHeaven search error: {e}")
            return []

    def get_episodes(self, anime_id: str) -> Tuple[List[Dict], str]:
        """Get episodes for anime from AnimeHeaven"""
        cache_key = f"animeheaven_episodes_{anime_id}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached, "cached"

        try:
            # Try to get anime info page
            url = f"{self.base_url}/anime/{anime_id}"
            response = self._make_request(url)
            if not response:
                return ([], "Unknown"), "error"

            soup = BeautifulSoup(response.content, 'html.parser')

            # Extract title
            title_elem = soup.find(['h1', 'h2'], class_=re.compile(r'title|name'))
            title = title_elem.get_text(strip=True) if title_elem else 'Unknown'

            # Try to find episode listing
            episodes = []

            # Look for episode list - common patterns
            episode_list = soup.find('div', class_=re.compile(r'episode-list|episodes|listing'))
            if not episode_list:
                episode_list = soup.find('ul', class_=re.compile(r'episode-list|episodes'))
            if not episode_list:
                # Try to find all links that look like episode links
                episode_list = soup

            # Find episode links/items
            episode_items = episode_list.find_all(['a', 'li'], href=re.compile(r'episode|ep-\d+|/ep/'))

            if episode_items:
                for item in episode_items:
                    try:
                        # Extract episode number and title
                        link = item if item.name == 'a' else item.find('a', href=True)
                        if not link:
                            continue

                        href = link.get('href', '')
                        text = link.get_text(strip=True)

                        # Extract episode number from text or URL
                        ep_num_match = re.search(r'[Ee]pisode[\s#]*(\d+)', text) or \
                                     re.search(r'ep[-\s]*(\d+)', href, re.I) or \
                                     re.search(r'/(\d+)(?:[/?]|$)', href)

                        if ep_num_match:
                            ep_num = int(ep_num_match.group(1))
                            ep_title = text if text and text != f"Episode {ep_num}" else f"Episode {ep_num}"

                            episodes.append({
                                "id": href.split('/')[-1] if href.split('/')[-1] else str(ep_num),
                                "num": ep_num,
                                "title": ep_title
                            })
                    except Exception as e:
                        logger.debug(f"Error parsing episode item: {e}")
                        continue

            # If no episodes found via parsing, try to infer from site structure
            if not episodes:
                # Look for any numbers that might be episode counts
                episode_text = soup.find(text=re.compile(r'\d+\s*episodes?', re.I))
                if episode_text:
                    ep_match = re.search(r'(\d+)', episode_text)
                    if ep_match:
                        total_episodes = int(ep_match.group(1))
                        for ep_num in range(1, total_episodes + 1):
                            episodes.append({
                                "id": str(ep_num),
                                "num": ep_num,
                                "title": f"Episode {ep_num}"
                            })

            # Sort episodes by number
            episodes.sort(key=lambda x: x["num"])

            result = (episodes, title)
            self._cache_set(cache_key, result)
            return result, "fresh"

        except Exception as e:
            logger.error(f"AnimeHeaven episodes error: {e}")
            return ([], "Unknown"), "error"

    def get_streaming_sources(self, episode_id: str) -> Dict:
        """Get streaming sources for episode from AnimeHeaven"""
        cache_key = f"animeheaven_sources_{episode_id}"
        cached = self._cache_get(cache_key)
        if cached:
            return cached

        try:
            # Try to get the episode/watch page
            url = f"{self.base_url}/watch/{episode_id}"
            response = self._make_request(url)
            if not response:
                return {'sources': [], 'subtitles': [], 'provider': 'animeheaven', 'error': 'Failed to load episode page'}

            soup = BeautifulSoup(response.content, 'html.parser')

            # Look for video player or iframe
            video_sources = []

            # Check for video tag
            video_tags = soup.find_all('video')
            for video in video_tags:
                src = video.get('src')
                if src:
                    video_sources.append({
                        'url': src,
                        'quality': 'default',
                        'isM3u8': '.m3u8' in src.lower()
                    })

                # Check for source tags within video
                source_tags = video.find_all('source')
                for source in source_tags:
                    src = source.get('src')
                    if src:
                        video_sources.append({
                            'url': src,
                            'quality': source.get('type', 'default').split('/')[-1] if source.get('type') else 'default',
                            'isM3u8': '.m3u8' in src.lower()
                        })

            # Check for iframes (common for embedded players)
            iframes = soup.find_all('iframe')
            for iframe in iframes:
                src = iframe.get('src')
                if src and ('vidstreaming' in src or 'mp4upload' in src or 'streamtape' in src or 'videomega' in src):
                    video_sources.append({
                        'url': src,
                        'quality': 'default',
                        'isM3u8': '.m3u8' in src.lower()
                    })

            # Look for direct video links in buttons or divs
            video_links = soup.find_all(['a', 'div', 'button'],
                                      attrs={'data-video': True, 'data-src': True, 'data-link': True})
            for link in video_links:
                src = link.get('data-video') or link.get('data-src') or link.get('data-link')
                if src and src.startswith('http'):
                    video_sources.append({
                        'url': src,
                        'quality': 'default',
                        'isM3u8': '.m3u8' in src.lower()
                    })

            # Look for script tags that might contain video URLs
            scripts = soup.find_all('script')
            for script in scripts:
                if script.string:
                    # Look for common video URL patterns
                    urls = re.findall(r'https?://[^\s"\']+\.(?:mp4|m3u8)', script.string)
                    for url in urls:
                        video_sources.append({
                            'url': url,
                            'quality': 'default',
                            'isM3u8': '.m3u8' in url.lower()
                        })

            # Deduplicate sources
            unique_sources = []
            seen_urls = set()
            for source in video_sources:
                if source['url'] not in seen_urls:
                    seen_urls.add(source['url'])
                    unique_sources.append(source)

            # Look for subtitles
            subtitles = []
            # Check for track tags within video
            video_tags = soup.find_all('video')
            for video in video_tags:
                track_tags = video.find_all('track', kind='subtitles')
                for track in track_tags:
                    src = track.get('src')
                    lang = track.get('srclang', 'en')
                    if src:
                        subtitles.append({
                            'url': src,
                            'lang': lang,
                            'kind': 'subtitles'
                        })

            # If no sources found, try to extract from page data
            if not unique_sources:
                # Try to find player configuration
                player_divs = soup.find_all(['div', 'script'],
                                          attrs={'data-player': True, 'id': re.compile(r'player|video')})
                for div in player_divs:
                    if div.name == 'script' and div.string:
                        # Look for player config in script
                        config_matches = re.findall(r'["\'](https?://[^\s"\']+\.(?:mp4|m3u8))["\']', div.string)
                        for url in config_matches:
                            unique_sources.append({
                                'url': url,
                                'quality': 'default',
                                'isM3u8': '.m3u8' in url.lower()
                            })
                    elif div.name == 'div':
                        # Check for data attributes
                        for attr in ['data-video', 'data-src', 'data-link']:
                            src = div.get(attr)
                            if src and src.startswith('http'):
                                unique_sources.append({
                                    'url': src,
                                    'quality': 'default',
                                    'isM3u8': '.m3u8' in src.lower()
                                })

            result = {
                'sources': unique_sources,
                'subtitles': subtitles,
                'provider': 'animeheaven'
            }

            self._cache_set(cache_key, result)
            return result

        except Exception as e:
            logger.error(f"AnimeHeaven streaming error: {e}")
            return {'sources': [], 'subtitles': [], 'provider': 'animeheaven', 'error': str(e)}


class StreamingManager:
    """Manages multiple streaming providers with fallback"""

    def __init__(self):
        self.providers = {
            'gogoanime': ConsumetProvider('gogoanime'),
            'zoro': ConsumetProvider('zoro'),
            'miruro': MiruroProvider(),
            'animeheaven': AnimeHeavenProvider(),  # Added AnimeHeaven provider
        }
        self.primary_provider = 'gogoanime'

    def search(self, query: str, provider: str = None) -> Dict:
        """Search with fallback to other providers"""
        if not provider:
            provider = self.primary_provider

        if provider not in self.providers:
            return {'error': f'Provider {provider} not found', 'results': []}

        # Try primary provider
        results = self.providers[provider].search(query)
        if results:
            return {'provider': provider, 'results': results, 'status': 'success'}

        # Fallback to other providers
        for prov_name, prov in self.providers.items():
            if prov_name != provider:
                results = prov.search(query)
                if results:
                    return {'provider': prov_name, 'results': results, 'status': 'fallback'}

        return {'error': 'No results found', 'results': [], 'status': 'failed'}

    def get_episodes(self, anime_id: str, provider: str = None) -> Dict:
        """Get episodes with fallback"""
        if not provider:
            provider = self.primary_provider

        if provider not in self.providers:
            return {'error': f'Provider {provider} not found', 'episodes': []}

        # Try primary provider
        episodes, title = self.providers[provider].get_episodes(anime_id)
        if episodes:
            return {
                'provider': provider,
                'anime_id': anime_id,
                'title': title,
                'episodes': episodes,
                'total': len(episodes),
                'status': 'success'
            }

        # Fallback
        for prov_name, prov in self.providers.items():
            if prov_name != provider:
                episodes, title = prov.get_episodes(anime_id)
                if episodes:
                    return {
                        'provider': prov_name,
                        'anime_id': anime_id,
                        'title': title,
                        'episodes': episodes,
                        'total': len(episodes),
                        'status': 'fallback'
                    }

        return {'error': 'No episodes found', 'episodes': [], 'status': 'failed'}

    def get_streaming_sources(self, episode_id: str, provider: str = None,
                             fallback_providers: List[str] = None) -> Dict:
        """Get streaming sources with fallback"""
        if not provider:
            provider = self.primary_provider

        if not fallback_providers:
            fallback_providers = [p for p in self.providers.keys() if p != provider]

        # Try primary
        sources = self.providers[provider].get_streaming_sources(episode_id)
        if sources.get('sources'):
            sources['status'] = 'success'
            return sources

        # Fallback to other providers
        for prov_name in fallback_providers:
            if prov_name in self.providers:
                sources = self.providers[prov_name].get_streaming_sources(episode_id)
                if sources.get('sources'):
                    sources['status'] = 'fallback'
                    sources['provider'] = prov_name
                    return sources

        return {
            'sources': [],
            'subtitles': [],
            'provider': provider,
            'status': 'failed',
            'error': 'No streaming sources found'
        }

    def get_trending(self, provider: str = None) -> Dict:
        """Get trending anime"""
        if not provider:
            provider = self.primary_provider

        if provider not in self.providers:
            return {'error': f'Provider {provider} not found', 'trending': []}

        trending = self.providers[provider].get_trending()
        return {
            'provider': provider,
            'trending': trending,
            'status': 'success' if trending else 'failed'
        }

    def clear_cache(self):
        """Clear all provider caches"""
        for provider in self.providers.values():
            provider.cache.clear()


# Global instance
streaming_manager = StreamingManager()