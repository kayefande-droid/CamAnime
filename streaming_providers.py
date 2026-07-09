"""
CamAnime Streaming Providers Module
Multi-source streaming integration with caching and fallback support
"""

import requests
import json
from typing import List, Dict, Optional, Tuple
from functools import lru_cache
import time

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
            data, timestamp = self.cache[key]\n            if time.time() - timestamp < self.cache_duration:
                return data\n        return None
    
    def _cache_set(self, key: str, value: Dict):
        """Cache a value"""
        self.cache[key] = (value, time.time())


class ConsumetProvider(StreamingProvider):
    \"\"\"Consumet.org API provider (GoGoAnime, Zoro)\"\"\"
    
    def __init__(self, provider_type='gogoanime', timeout=10):
        super().__init__(timeout)
        self.base_url = 'https://api.consumet.org'
        self.provider_type = provider_type  # 'gogoanime' or 'zoro'
        
    def search(self, query: str) -> List[Dict]:
        \"\"\"Search anime on Consumet\"\"\"
        cache_key = f\"consumet_search_{self.provider_type}_{query}\"
        cached = self._cache_get(cache_key)
        if cached:
            return cached
            
        try:
            url = f\"{self.base_url}/anime/{self.provider_type}/search\"
            params = {'query': query}
            response = requests.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()
            
            data = response.json()
            results = data.get('results', [])
            
            self._cache_set(cache_key, results)
            return results
            
        except Exception as e:
            print(f\"Consumet search error ({self.provider_type}): {e}\")
            return []
    
    def get_episodes(self, anime_id: str) -> Tuple[List[Dict], str]:
        \"\"\"Get episodes for anime\"\"\"
        cache_key = f\"consumet_episodes_{self.provider_type}_{anime_id}\"
        cached = self._cache_get(cache_key)
        if cached:
            return cached, \"cached\"
            
        try:
            url = f\"{self.base_url}/anime/{self.provider_type}/info\"
            params = {'id': anime_id}
            response = requests.get(url, params=params, timeout=self.timeout)
            response.raise_for_status()
            
            data = response.json()
            episodes = data.get('episodes', [])
            title = data.get('title', 'Unknown')
            
            result = (episodes, title)
            self._cache_set(cache_key, result)
            return result, \"fresh\"
            
        except Exception as e:
            print(f\"Consumet episodes error ({self.provider_type}): {e}\")
            return ([], \"Unknown\"), \"error\"
    
    def get_streaming_sources(self, episode_id: str) -> Dict:
        \"\"\"Get streaming sources for episode\"\"\"
        cache_key = f\"consumet_sources_{self.provider_type}_{episode_id}\"
        cached = self._cache_get(cache_key)
        if cached:
            return cached
            
        try:
            url = f\"{self.base_url}/anime/{self.provider_type}/watch\"
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
            print(f\"Consumet streaming error ({self.provider_type}): {e}\")
            return {'sources': [], 'subtitles': [], 'provider': self.provider_type, 'error': str(e)}
    
    def _format_sources(self, sources: List[Dict]) -> List[Dict]:
        \"\"\"Format streaming sources\"\"\"
        formatted = []
        for source in sources:
            formatted.append({
                'url': source.get('url', ''),
                'quality': source.get('quality', 'default'),
                'isM3u8': '.m3u8' in source.get('url', '').lower()
            })
        return formatted
    
    def _format_subtitles(self, subtitles: List[Dict]) -> List[Dict]:
        \"\"\"Format subtitles\"\"\"
        formatted = []
        for sub in subtitles:
            formatted.append({
                'url': sub.get('url', ''),
                'lang': sub.get('lang', 'Unknown'),
                'kind': 'subtitles'
            })
        return formatted
    
    def get_trending(self) -> List[Dict]:
        \"\"\"Get trending anime\"\"\"
        cache_key = f\"consumet_trending_{self.provider_type}\"
        cached = self._cache_get(cache_key)
        if cached:
            return cached
            
        try:
            url = f\"{self.base_url}/anime/{self.provider_type}/recent-episodes\"
            response = requests.get(url, timeout=self.timeout)
            response.raise_for_status()
            
            data = response.json()
            results = data.get('results', [])
            
            self._cache_set(cache_key, results)
            return results
            
        except Exception as e:
            print(f\"Consumet trending error ({self.provider_type}): {e}\")
            return []


class StreamingManager:
    \"\"\"Manages multiple streaming providers with fallback\"\"\"
    
    def __init__(self):
        self.providers = {
            'gogoanime': ConsumetProvider('gogoanime'),
            'zoro': ConsumetProvider('zoro'),
        }
        self.primary_provider = 'gogoanime'
    
    def search(self, query: str, provider: str = None) -> Dict:
        \"\"\"Search with fallback to other providers\"\"\"
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
        \"\"\"Get episodes with fallback\"\"\"
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
        \"\"\"Get streaming sources with fallback\"\"\"
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
        \"\"\"Get trending anime\"\"\"
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
        \"\"\"Clear all provider caches\"\"\"
        for provider in self.providers.values():
            provider.cache.clear()


# Global instance
streaming_manager = StreamingManager()
