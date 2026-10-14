# CamAnime TikTok video kit (Remotion spec)

15s vertical video, 1080x1920, 30fps. Generate with Remotion on your device:

```bash
npx create-video@latest camanime-tiktok --template blank
cd camanime-tiktok
npm i remotion @remotion/cli
```

Composition `CamAnimePromo` (450 frames):
- 0–90f: Logo sting. KD monogram (white K + electric-blue D + `</>`) + "CamAnime — FREE 1080p" + tag "Free anime streaming website". Spring-in scale, accent glow pulse.
- 90–240f: App proof. Screen-record search → trailer → episode 1 play (drop your capture into `public/`). Caption pages TikTok-style, 3 words per page.
- 240–360f: Server switch SUB/DUB + Download-to-library tap. Highlight "hidden in-app library → Save to device".
- 360–450f: End card. QR to `https://<your-host>/promo` + "Link in bio" + creator logo block.

Render: `npx remotion render CamAnimePromo out/tiktok.mp4 --codec h264`.

Slide 1 of the /promo flyer carries your Kayefande-Droid creator logo (white KD + blue D-loop + SOFTWARE ENGINEER + CODE/BUILD/INNOVATE ring) as the advert opener.
