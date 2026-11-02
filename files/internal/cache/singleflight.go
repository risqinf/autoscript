package cache

import (
	"hash/fnv"
	"strings"
	"sync"
	"time"
)

type cacheEntry struct {
	val       interface{}
	expiresAt int64 // UnixNano
}

type inflightCall struct {
	wg  sync.WaitGroup
	val interface{}
	err error
}

// SnapshotCache provides thread-safe micro-TTL caching with Singleflight request coalescing.
// Under massive burst concurrency (100k–1M concurrent requests), simultaneous cache misses on the
// same key coalesce onto a single underlying computation without spawning duplicate subprocesses or DB scans.
type SnapshotCache struct {
	mu       sync.RWMutex
	entries  map[string]cacheEntry
	inflight map[string]*inflightCall
}

// NewSnapshotCache creates a new SnapshotCache.
func NewSnapshotCache() *SnapshotCache {
	c := &SnapshotCache{
		entries:  make(map[string]cacheEntry, 128),
		inflight: make(map[string]*inflightCall, 32),
	}
	return c
}

// GetOrLoad returns the cached value if valid, or coalesces concurrent callers onto fn().
func (c *SnapshotCache) GetOrLoad(key string, ttl time.Duration, fn func() (interface{}, error)) (interface{}, error) {
	now := time.Now().UnixNano()

	c.mu.RLock()
	if ent, ok := c.entries[key]; ok && now < ent.expiresAt {
		c.mu.RUnlock()
		return ent.val, nil
	}
	c.mu.RUnlock()

	c.mu.Lock()
	// Re-check under write lock
	now = time.Now().UnixNano()
	if ent, ok := c.entries[key]; ok && now < ent.expiresAt {
		c.mu.Unlock()
		return ent.val, nil
	}

	if call, ok := c.inflight[key]; ok {
		c.mu.Unlock()
		call.wg.Wait()
		return call.val, call.err
	}

	call := &inflightCall{}
	call.wg.Add(1)
	c.inflight[key] = call
	c.mu.Unlock()

	val, err := fn()

	c.mu.Lock()
	call.val = val
	call.err = err
	delete(c.inflight, key)
	if err == nil && ttl > 0 {
		c.entries[key] = cacheEntry{
			val:       val,
			expiresAt: time.Now().Add(ttl).UnixNano(),
		}
	}
	call.wg.Done()
	c.mu.Unlock()

	return val, err
}

// InvalidatePrefix removes cached keys starting with prefix.
func (c *SnapshotCache) InvalidatePrefix(prefix string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k := range c.entries {
		if strings.HasPrefix(k, prefix) {
			delete(c.entries, k)
		}
	}
}

// InvalidateAll clears all cached snapshots.
func (c *SnapshotCache) InvalidateAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	clear(c.entries)
}

// Prune removes expired entries to keep memory bounded.
func (c *SnapshotCache) Prune() {
	now := time.Now().UnixNano()
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, v := range c.entries {
		if now >= v.expiresAt {
			delete(c.entries, k)
		}
	}
}

// IdempotencyRecord stores the result of a previously completed idempotent bulk operation.
type IdempotencyRecord struct {
	Payload   []byte
	Status    int
	ExpiresAt int64
}

type idemShard struct {
	mu    sync.RWMutex
	items map[string]IdempotencyRecord
}

// IdempotencyStore is a 64-shard TTL cache preventing duplicate Flash-Sale bulk creations on client retry.
type IdempotencyStore struct {
	shards [64]idemShard
	ttl    time.Duration
}

// NewIdempotencyStore creates a new sharded idempotency store.
func NewIdempotencyStore(ttl time.Duration) *IdempotencyStore {
	s := &IdempotencyStore{ttl: ttl}
	for i := range s.shards {
		s.shards[i].items = make(map[string]IdempotencyRecord)
	}
	return s
}

func (s *IdempotencyStore) shardFor(key string) *idemShard {
	h := fnv.New32a()
	_, _ = h.Write([]byte(key))
	return &s.shards[h.Sum32()&63]
}

// Get retrieves a stored response for an idempotency key if not expired.
func (s *IdempotencyStore) Get(key string) (IdempotencyRecord, bool) {
	if key == "" {
		return IdempotencyRecord{}, false
	}
	sh := s.shardFor(key)
	now := time.Now().Unix()

	sh.mu.RLock()
	rec, ok := sh.items[key]
	sh.mu.RUnlock()
	if !ok || now >= rec.ExpiresAt {
		return IdempotencyRecord{}, false
	}
	return rec, true
}

// Set stores a completed response for an idempotency key.
func (s *IdempotencyStore) Set(key string, status int, payload []byte) {
	if key == "" {
		return
	}
	sh := s.shardFor(key)
	now := time.Now().Unix()
	exp := now + int64(s.ttl.Seconds())

	sh.mu.Lock()
	if len(sh.items) >= 2048 {
		for k, v := range sh.items {
			if now >= v.ExpiresAt {
				delete(sh.items, k)
			}
		}
		// Hard cap eviction if still full
		if len(sh.items) >= 2048 {
			for k := range sh.items {
				delete(sh.items, k)
				break
			}
		}
	}
	copied := make([]byte, len(payload))
	copy(copied, payload)
	sh.items[key] = IdempotencyRecord{
		Payload:   copied,
		Status:    status,
		ExpiresAt: exp,
	}
	sh.mu.Unlock()
}
