package service

import (
	"bufio"
	"io"
	"net"
	"os"
	"strings"
)

type appRule struct {
	substr   string
	app      string
	category string
}

var domainAppRules = []appRule{
	// Video & Streaming
	{"googlevideo.com", "YouTube", "streaming"},
	{"youtube.com", "YouTube", "streaming"},
	{"ytimg.com", "YouTube", "streaming"},
	{"youtu.be", "YouTube", "streaming"},
	{"netflix.com", "Netflix", "streaming"},
	{"nflxvideo.net", "Netflix", "streaming"},
	{"nflxso.net", "Netflix", "streaming"},
	{"tiktokcdn", "TikTok", "social"},
	{"tiktokv.com", "TikTok", "social"},
	{"tiktok.com", "TikTok", "social"},
	{"byteoversea.com", "TikTok", "social"},
	{"musical.ly", "TikTok", "social"},
	{"spotify.com", "Spotify", "streaming"},
	{"scdn.co", "Spotify", "streaming"},
	{"twitch.tv", "Twitch", "streaming"},
	{"ttvnw.net", "Twitch", "streaming"},
	{"disneyplus.com", "Disney+", "streaming"},
	{"bamgrid.com", "Disney+", "streaming"},
	{"vidio.com", "Vidio", "streaming"},
	{"viu.com", "Viu", "streaming"},
	{"primevideo.com", "Prime Video", "streaming"},
	{"bilibili", "Bilibili", "streaming"},

	// Social & Messaging
	{"instagram.com", "Instagram", "social"},
	{"cdninstagram.com", "Instagram", "social"},
	{"whatsapp.net", "WhatsApp", "messaging"},
	{"whatsapp.com", "WhatsApp", "messaging"},
	{"facebook.com", "Facebook", "social"},
	{"fbcdn.net", "Facebook", "social"},
	{"messenger.com", "Messenger", "messaging"},
	{"telegram.org", "Telegram", "messaging"},
	{"t.me", "Telegram", "messaging"},
	{"tdesktop.com", "Telegram", "messaging"},
	{"discord.com", "Discord", "messaging"},
	{"discordapp.com", "Discord", "messaging"},
	{"discord.gg", "Discord", "messaging"},
	{"twitter.com", "X (Twitter)", "social"},
	{"twimg.com", "X (Twitter)", "social"},
	{"x.com", "X (Twitter)", "social"},
	{"reddit.com", "Reddit", "social"},
	{"redd.it", "Reddit", "social"},
	{"threads.net", "Threads", "social"},
	{"line.me", "LINE", "messaging"},
	{"snapchat.com", "Snapchat", "social"},
	{"pinterest.com", "Pinterest", "social"},
	{"linkedin.com", "LinkedIn", "social"},

	// Gaming
	{"mobilelegends.com", "Mobile Legends", "gaming"},
	{"moonton.com", "Mobile Legends", "gaming"},
	{"youngjoygame.com", "Mobile Legends", "gaming"},
	{"pubgmobile.com", "PUBG Mobile", "gaming"},
	{"igamecj.com", "PUBG Mobile", "gaming"},
	{"proximabeta.com", "Honor of Kings / Level Infinite", "gaming"},
	{"garena.com", "Garena / Free Fire", "gaming"},
	{"freefiremobile.com", "Free Fire", "gaming"},
	{"hoyoverse.com", "HoYoverse (Genshin/HSR)", "gaming"},
	{"mihoyo.com", "HoYoverse (Genshin/HSR)", "gaming"},
	{"roblox.com", "Roblox", "gaming"},
	{"rbxcdn.com", "Roblox", "gaming"},
	{"steampowered.com", "Steam", "gaming"},
	{"steamcommunity.com", "Steam", "gaming"},
	{"steamserver.net", "Steam", "gaming"},
	{"riotgames.com", "Riot Games / Valorant", "gaming"},
	{"epicgames.com", "Epic Games", "gaming"},

	// AI & Developer
	{"openai.com", "ChatGPT / OpenAI", "ai"},
	{"chatgpt.com", "ChatGPT / OpenAI", "ai"},
	{"oaistatic.com", "ChatGPT / OpenAI", "ai"},
	{"anthropic.com", "Claude AI", "ai"},
	{"claude.ai", "Claude AI", "ai"},
	{"gemini.google.com", "Google Gemini", "ai"},
	{"perplexity.ai", "Perplexity AI", "ai"},
	{"deepseek.com", "DeepSeek AI", "ai"},
	{"github.com", "GitHub", "developer"},
	{"githubusercontent.com", "GitHub", "developer"},
	{"gitlab.com", "GitLab", "developer"},

	// E-Commerce & Finance (SEA / Global)
	{"shopee.", "Shopee", "ecommerce"},
	{"shopeemobile.com", "Shopee", "ecommerce"},
	{"tokopedia.com", "Tokopedia", "ecommerce"},
	{"lazada.", "Lazada", "ecommerce"},
	{"bukalapak.com", "Bukalapak", "ecommerce"},
	{"gojek.com", "Gojek", "ecommerce"},
	{"gopay.co.id", "GoPay", "ecommerce"},
	{"grab.com", "Grab", "ecommerce"},
	{"dana.id", "DANA", "ecommerce"},
	{"ovo.id", "OVO", "ecommerce"},
	{"amazon.com", "Amazon", "ecommerce"},
	{"binance.com", "Binance", "finance"},
	{"tradingview.com", "TradingView", "finance"},

	// Productivity & Cloud
	{"zoom.us", "Zoom", "productivity"},
	{"meet.google.com", "Google Meet", "productivity"},
	{"microsoft.com", "Microsoft", "productivity"},
	{"office.com", "Microsoft 365", "productivity"},
	{"live.com", "Microsoft Live", "productivity"},
	{"apple.com", "Apple Services", "cloud"},
	{"icloud.com", "Apple iCloud", "cloud"},
	{"googleapis.com", "Google Services", "cloud"},
	{"gstatic.com", "Google Services", "cloud"},
	{"google.com", "Google", "web"},
	{"1e100.net", "Google", "web"},
	{"cloudflare.com", "Cloudflare", "cdn"},
	{"cloudflare-dns.com", "Cloudflare DNS", "cdn"},
	{"fast.com", "Speedtest (Fast.com)", "utility"},
	{"speedtest.net", "Speedtest (Ookla)", "utility"},
}

// ClassifyDomainApp maps a destination hostname or IP to a friendly App name and category.
func ClassifyDomainApp(host string) (appName string, category string) {
	clean := strings.ToLower(strings.TrimSpace(host))
	if h, _, err := net.SplitHostPort(clean); err == nil && h != "" {
		clean = h
	}
	clean = strings.TrimSuffix(clean, ".")
	if clean == "" {
		return "Unknown", "other"
	}

	// Well-known Anycast IPv4 addresses (Telegram DC, DNS, Meta)
	if ip := net.ParseIP(clean); ip != nil {
		switch {
		case strings.HasPrefix(clean, "149.154.") || strings.HasPrefix(clean, "91.108."):
			return "Telegram", "messaging"
		case clean == "8.8.8.8" || clean == "8.8.4.4":
			return "Google DNS", "cdn"
		case clean == "1.1.1.1" || clean == "1.0.0.1":
			return "Cloudflare DNS", "cdn"
		default:
			return "Direct IP (" + clean + ")", "direct"
		}
	}

	for _, rule := range domainAppRules {
		if strings.Contains(clean, rule.substr) {
			return rule.app, rule.category
		}
	}

	// Derive readable domain root e.g. sub.news.detik.com -> detik.com
	parts := strings.Split(clean, ".")
	if len(parts) >= 2 {
		root := parts[len(parts)-2] + "." + parts[len(parts)-1]
		if len(parts) >= 3 && len(parts[len(parts)-1]) == 2 && len(parts[len(parts)-2]) <= 3 {
			root = parts[len(parts)-3] + "." + root
		}
		return "Web (" + root + ")", "web"
	}

	return clean, "web"
}

// LoadDNSCacheMap reads the tail of /var/log/autoscript-dns.log (written by dnsmasq-autoscript)
// to build a fast IP -> queried domain map for SSH, Dropbear, SlowDNS, and OpenVPN sessions!
func LoadDNSCacheMap(dnsLogPath string) map[string]string {
	ipToDomain := make(map[string]string, 256)
	if dnsLogPath == "" {
		return ipToDomain
	}

	f, err := os.Open(dnsLogPath)
	if err != nil {
		return ipToDomain
	}
	defer f.Close()

	// Seek to last 256KB so parsing stays < 1ms even on busy servers
	if st, err := f.Stat(); err == nil && st.Size() > 262144 {
		_, _ = f.Seek(st.Size()-262144, io.SeekStart)
	}

	// dnsmasq log-queries format: "reply <domain> is <ip>"
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		idx := strings.Index(line, "reply ")
		if idx < 0 {
			continue
		}
		rest := line[idx+6:]
		fields := strings.Fields(rest)
		// fields: [domain, "is", ip]
		if len(fields) >= 3 && fields[1] == "is" {
			dom := strings.ToLower(strings.TrimSuffix(fields[0], "."))
			ip := fields[2]
			if net.ParseIP(ip) != nil && dom != "" && !strings.HasPrefix(dom, "<") {
				ipToDomain[ip] = dom
			}
		}
	}
	return ipToDomain
}
