# CamAnime - Watch Anime Online Free

CamAnime is a free anime streaming website that allows users to watch their favorite anime series and movies online. The platform aggregates content from various legal streaming sources and provides a clean, user-friendly interface for discovering and watching anime.

## Features

- **Extensive Anime Library**: Access to thousands of anime titles from various genres
- **High-Quality Streaming**: Multiple streaming options with different quality settings
- **User-Friendly Interface**: Clean and intuitive design for easy navigation
- **Search Functionality**: Quickly find your favorite anime by title or genre
- **Anime Details**: View detailed information including synopsis, ratings, and episode lists
- **Responsive Design**: Works seamlessly on desktop, tablet, and mobile devices

## Technology Stack

- **Backend**: Python Flask
- **Frontend**: HTML5, CSS3, JavaScript
- **API Integration**: AniList for anime metadata
- **Streaming Providers**: Multiple anime streaming sources with fallback mechanisms

## Installation

1. Clone the repository:
   ```
   git clone https://github.com/kayefande-droid/CamAnime.git
   ```

2. Install dependencies:
   ```
   pip install -r requirements.txt
   ```

3. Run the application:
   ```
   python app.py
   ```

4. Open your browser and visit: http://localhost:5000

## Project Structure

- `app.py` - Main Flask application
- `streaming_providers.py` - Handles connections to various anime streaming providers
- `/templates` - HTML templates for different pages
- `requirements.txt` - Python dependencies

## Screenshots

![Home Page](screenshots/home.png)
*CamAnime home page showing featured anime*

![Anime Details](screenshots/details.png)
*Detailed view of an anime series*

![Watch Page](screenshots/watch.png)
*Anime streaming player interface*

*Note: Screenshots directory and images would be added as the project develops.*

## API Integration

CamAnime uses the AniList GraphQL API to fetch anime metadata including:
- Titles (English and Japanese/Romaji)
- Descriptions and synopses
- Cover images and banners
- Genres and formats
- Ratings and popularity scores
- Episode information and airing schedules

## Streaming Providers

The platform integrates with multiple anime streaming providers to ensure reliable content availability:
- Primary providers (with fallback mechanisms)
- Provider health checking and automatic failover
- Multiple quality options per title
- Subtitle support where available

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is open source and available under the MIT License.

## Disclaimer

CamAnime does not host any content directly. All anime is streamed from official, legal sources. We comply with all copyright laws and regulations.
## Recent Improvements

- Added AnimeHeaven provider to expand anime library access and improve streaming reliability
- Enhanced fallback mechanisms to ensure continuous service availability
- Improved error handling and logging throughout the application
- Optimized image loading with responsive design techniques
