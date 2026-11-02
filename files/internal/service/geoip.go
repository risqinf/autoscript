package service

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/risqinf/autoscript-api/internal/model"
)

type cachedGeo struct {
	geo       model.GeoLocation
	expiresAt int64
}

// GeoIPResolver resolves client IP addresses to ISP/ASN and geographic location using free APIs
// (ip-api.com batch -> ipwho.is -> freeipapi.com) with 24h RAM caching and /run/autoscript-geoip.cache sync.
type GeoIPResolver struct {
	mu        sync.RWMutex
	cache     map[string]cachedGeo
	cacheFile string
	client    *http.Client
}

// NewGeoIPResolver creates a new GeoIPResolver.
func NewGeoIPResolver(cacheFile string) *GeoIPResolver {
	r := &GeoIPResolver{
		cache:     make(map[string]cachedGeo, 512),
		cacheFile: cacheFile,
		client: &http.Client{
			Timeout: 2500 * time.Millisecond,
		},
	}
	r.loadDiskCache()
	return r
}

func (r *GeoIPResolver) loadDiskCache() {
	if r.cacheFile == "" {
		return
	}
	f, err := os.Open(r.cacheFile)
	if err != nil {
		return
	}
	defer f.Close()

	now := time.Now().Unix()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		// Format compatible with scripts/lib/common.sh: ip|ts|isp|location
		parts := strings.Split(sc.Text(), "|")
		if len(parts) < 4 {
			continue
		}
		ip := strings.TrimSpace(parts[0])
		ts, _ := strconv.ParseInt(strings.TrimSpace(parts[1]), 10, 64)
		if ip == "" || now-ts > 86400 {
			continue
		}
		isp := strings.TrimSpace(parts[2])
		loc := strings.TrimSpace(parts[3])
		city, country := "", loc
		if idx := strings.Index(loc, ","); idx > 0 {
			city = strings.TrimSpace(loc[:idx])
			country = strings.TrimSpace(loc[idx+1:])
		}
		r.cache[ip] = cachedGeo{
			geo: model.GeoLocation{
				IP:      ip,
				City:    city,
				Country: country,
				ISP:     isp,
				Source:  "disk-cache",
			},
			expiresAt: ts + 86400,
		}
	}
}

func (r *GeoIPResolver) appendDiskCache(g model.GeoLocation) {
	if r.cacheFile == "" || g.IP == "" {
		return
	}
	loc := g.Country
	if g.City != "" && g.Country != "" {
		loc = g.City + ", " + g.Country
	}
	line := fmt.Sprintf("%s|%d|%s|%s\n",
		sanitizePipe(g.IP), time.Now().Unix(), sanitizePipe(g.ISP), sanitizePipe(loc))
	f, err := os.OpenFile(r.cacheFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return
	}
	_, _ = f.WriteString(line)
	_ = f.Close()
}

func sanitizePipe(s string) string {
	return strings.NewReplacer("|", " ", "\n", " ", "\r", " ").Replace(s)
}

func isPrivateOrLoopbackIP(ipStr string) (bool, model.GeoLocation) {
	parsed := net.ParseIP(ipStr)
	if parsed == nil {
		return true, model.GeoLocation{IP: ipStr, Country: "Unknown", ISP: "Unknown"}
	}
	if parsed.IsLoopback() || parsed.IsPrivate() || parsed.IsLinkLocalUnicast() {
		return true, model.GeoLocation{
			IP:          ipStr,
			Country:     "Local Network",
			CountryCode: "LO",
			City:        "Internal",
			ISP:         "Private / Loopback",
			Source:      "rfc1918",
		}
	}
	return false, model.GeoLocation{}
}

// LookupBatch resolves a slice of public IPs efficiently (cached first, then batch ip-api.com, then fallbacks).
func (r *GeoIPResolver) LookupBatch(ctx context.Context, ips []string) map[string]model.GeoLocation {
	out := make(map[string]model.GeoLocation, len(ips))
	if len(ips) == 0 {
		return out
	}

	now := time.Now().Unix()
	var missing []string
	seen := make(map[string]bool, len(ips))

	r.mu.RLock()
	for _, rawIP := range ips {
		ip := strings.TrimSpace(rawIP)
		if ip == "" || seen[ip] {
			continue
		}
		seen[ip] = true
		if priv, g := isPrivateOrLoopbackIP(ip); priv {
			out[ip] = g
			continue
		}
		if ent, ok := r.cache[ip]; ok && now < ent.expiresAt {
			out[ip] = ent.geo
			continue
		}
		missing = append(missing, ip)
	}
	r.mu.RUnlock()

	if len(missing) == 0 {
		return out
	}

	// Tier 1: Batch POST to ip-api.com (up to 100 IPs per single request, free & fast)
	for start := 0; start < len(missing); start += 100 {
		end := start + 100
		if end > len(missing) {
			end = len(missing)
		}
		chunk := missing[start:end]
		resolved := r.queryIPAPIBatch(ctx, chunk)
		for _, ip := range chunk {
			if g, ok := resolved[ip]; ok && g.ISP != "" {
				r.store(ip, g)
				out[ip] = g
				continue
			}
			// Tier 2: ipwho.is fallback
			if g, ok := r.queryIPWhois(ctx, ip); ok {
				r.store(ip, g)
				out[ip] = g
				continue
			}
			// Tier 3: freeipapi.com fallback
			if g, ok := r.queryFreeIPAPI(ctx, ip); ok {
				r.store(ip, g)
				out[ip] = g
				continue
			}
			out[ip] = model.GeoLocation{
				IP:      ip,
				Country: "Unknown",
				ISP:     "Unknown",
				Source:  "unavailable",
			}
		}
	}

	return out
}

func (r *GeoIPResolver) store(ip string, g model.GeoLocation) {
	r.mu.Lock()
	if len(r.cache) > 8192 {
		now := time.Now().Unix()
		for k, v := range r.cache {
			if now >= v.expiresAt {
				delete(r.cache, k)
			}
		}
	}
	r.cache[ip] = cachedGeo{
		geo:       g,
		expiresAt: time.Now().Unix() + 86400,
	}
	r.mu.Unlock()
	r.appendDiskCache(g)
}

func (r *GeoIPResolver) queryIPAPIBatch(ctx context.Context, ips []string) map[string]model.GeoLocation {
	res := make(map[string]model.GeoLocation, len(ips))
	body, err := json.Marshal(ips)
	if err != nil {
		return res
	}

	reqCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, "POST",
		"http://ip-api.com/batch?fields=query,status,country,countryCode,regionName,city,isp,org,as,lat,lon,timezone",
		bytes.NewReader(body))
	if err != nil {
		return res
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := r.client.Do(req)
	if err != nil {
		return res
	}
	defer resp.Body.Close()

	var items []struct {
		Query       string  `json:"query"`
		Status      string  `json:"status"`
		Country     string  `json:"country"`
		CountryCode string  `json:"countryCode"`
		RegionName  string  `json:"regionName"`
		City        string  `json:"city"`
		ISP         string  `json:"isp"`
		Org         string  `json:"org"`
		AS          string  `json:"as"`
		Lat         float64 `json:"lat"`
		Lon         float64 `json:"lon"`
		Timezone    string  `json:"timezone"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&items); err != nil {
		return res
	}

	for _, it := range items {
		if it.Status != "success" || it.Query == "" {
			continue
		}
		isp := it.ISP
		if isp == "" {
			isp = it.Org
		}
		res[it.Query] = model.GeoLocation{
			IP:          it.Query,
			Country:     it.Country,
			CountryCode: it.CountryCode,
			Region:      it.RegionName,
			City:        it.City,
			ISP:         isp,
			Org:         it.Org,
			ASN:         it.AS,
			Timezone:    it.Timezone,
			Latitude:    it.Lat,
			Longitude:   it.Lon,
			Source:      "ip-api.com",
		}
	}
	return res
}

func (r *GeoIPResolver) queryIPWhois(ctx context.Context, ip string) (model.GeoLocation, bool) {
	reqCtx, cancel := context.WithTimeout(ctx, 1800*time.Millisecond)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, "GET", "https://ipwho.is/"+ip, nil)
	if err != nil {
		return model.GeoLocation{}, false
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return model.GeoLocation{}, false
	}
	defer resp.Body.Close()

	var data struct {
		Success     bool    `json:"success"`
		Country     string  `json:"country"`
		CountryCode string  `json:"country_code"`
		Region      string  `json:"region"`
		City        string  `json:"city"`
		Latitude    float64 `json:"latitude"`
		Longitude   float64 `json:"longitude"`
		Connection  struct {
			ASN int    `json:"asn"`
			Org string `json:"org"`
			ISP string `json:"isp"`
		} `json:"connection"`
		Timezone struct {
			ID string `json:"id"`
		} `json:"timezone"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil || !data.Success {
		return model.GeoLocation{}, false
	}
	isp := data.Connection.ISP
	if isp == "" {
		isp = data.Connection.Org
	}
	asn := ""
	if data.Connection.ASN > 0 {
		asn = fmt.Sprintf("AS%d", data.Connection.ASN)
	}
	return model.GeoLocation{
		IP:          ip,
		Country:     data.Country,
		CountryCode: data.CountryCode,
		Region:      data.Region,
		City:        data.City,
		ISP:         isp,
		Org:         data.Connection.Org,
		ASN:         asn,
		Timezone:    data.Timezone.ID,
		Latitude:    data.Latitude,
		Longitude:   data.Longitude,
		Source:      "ipwho.is",
	}, true
}

func (r *GeoIPResolver) queryFreeIPAPI(ctx context.Context, ip string) (model.GeoLocation, bool) {
	reqCtx, cancel := context.WithTimeout(ctx, 1800*time.Millisecond)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, "GET", "https://freeipapi.com/api/json/"+ip, nil)
	if err != nil {
		return model.GeoLocation{}, false
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return model.GeoLocation{}, false
	}
	defer resp.Body.Close()

	var data struct {
		IPAddress   string  `json:"ipAddress"`
		CountryName string  `json:"countryName"`
		CountryCode string  `json:"countryCode"`
		RegionName  string  `json:"regionName"`
		CityName    string  `json:"cityName"`
		Latitude    float64 `json:"latitude"`
		Longitude   float64 `json:"longitude"`
		ASNOrg      string  `json:"asnOrganization"`
		ASN         string  `json:"asn"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil || data.CountryName == "" {
		return model.GeoLocation{}, false
	}
	isp := data.ASNOrg
	if isp == "" {
		isp = "Public Network"
	}
	return model.GeoLocation{
		IP:          ip,
		Country:     data.CountryName,
		CountryCode: data.CountryCode,
		Region:      data.RegionName,
		City:        data.CityName,
		ISP:         isp,
		Org:         data.ASNOrg,
		ASN:         data.ASN,
		Latitude:    data.Latitude,
		Longitude:   data.Longitude,
		Source:      "freeipapi.com",
	}, true
}
