package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/pulseurl/pulseurl-go/client"
)

func TestNew(t *testing.T) {
	// Create a test client
	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10,
		FlushInterval: 1 * time.Second,
		Timeout:       100 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	// Create middleware
	mw := New(Config{
		Client: c,
		SkipPaths: []string{
			"/health",
		},
		CustomLabels: map[string]string{
			"env": "test",
		},
		ServiceName: "test-service",
		Namespace:   "test-namespace",
	})

	if mw == nil {
		t.Fatal("Expected middleware to be created")
	}
}

func TestMiddlewareBasicRequest(t *testing.T) {
	// Set Gin to test mode
	gin.SetMode(gin.TestMode)

	// Create test client
	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10,
		FlushInterval: 1 * time.Second,
		Timeout:       100 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	// Create router with middleware
	router := gin.New()
	router.Use(New(Config{
		Client:      c,
		ServiceName: "test-service",
		Namespace:   "test",
	}))

	router.GET("/test", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"message": "success"})
	})

	// Send test request
	req := httptest.NewRequest("GET", "/test", nil)
	w := httptest.NewRecorder()

	router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	// Give a moment for async logging
	time.Sleep(50 * time.Millisecond)
}

func TestMiddlewareSkipPaths(t *testing.T) {
	gin.SetMode(gin.TestMode)

	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10,
		FlushInterval: 1 * time.Second,
		Timeout:       100 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	router := gin.New()
	router.Use(New(Config{
		Client: c,
		SkipPaths: []string{
			"/health",
			"/metrics",
		},
	}))

	router.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"status": "ok"})
	})

	router.GET("/api/test", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"message": "success"})
	})

	// Test skipped path
	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	// Test non-skipped path
	req = httptest.NewRequest("GET", "/api/test", nil)
	w = httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Errorf("Expected status 200, got %d", w.Code)
	}
}

func TestMiddlewareWithDifferentMethods(t *testing.T) {
	gin.SetMode(gin.TestMode)

	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10,
		FlushInterval: 1 * time.Second,
		Timeout:       100 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	router := gin.New()
	router.Use(NewWithClient(c))

	router.GET("/test", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"method": "GET"})
	})

	router.POST("/test", func(ctx *gin.Context) {
		ctx.JSON(201, gin.H{"method": "POST"})
	})

	router.PUT("/test", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"method": "PUT"})
	})

	router.DELETE("/test", func(ctx *gin.Context) {
		ctx.Status(204)
	})

	// Test each method
	methods := []struct {
		method       string
		expectedCode int
	}{
		{"GET", 200},
		{"POST", 201},
		{"PUT", 200},
		{"DELETE", 204},
	}

	for _, m := range methods {
		req := httptest.NewRequest(m.method, "/test", nil)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)

		if w.Code != m.expectedCode {
			t.Errorf("Expected status %d for %s, got %d", m.expectedCode, m.method, w.Code)
		}
	}
}

func TestMiddlewareWithParams(t *testing.T) {
	gin.SetMode(gin.TestMode)

	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10,
		FlushInterval: 1 * time.Second,
		Timeout:       100 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	router := gin.New()
	router.Use(NewWithClient(c))

	router.GET("/users/:id", func(ctx *gin.Context) {
		id := ctx.Param("id")
		ctx.JSON(200, gin.H{"id": id})
	})

	// Test with parameter
	req := httptest.NewRequest("GET", "/users/123", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Errorf("Expected status 200, got %d", w.Code)
	}
}

func TestMiddlewareWithError(t *testing.T) {
	gin.SetMode(gin.TestMode)

	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10,
		FlushInterval: 1 * time.Second,
		Timeout:       100 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	router := gin.New()
	router.Use(NewWithClient(c))

	router.GET("/error", func(ctx *gin.Context) {
		ctx.JSON(500, gin.H{"error": "internal error"})
	})

	req := httptest.NewRequest("GET", "/error", nil)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != 500 {
		t.Errorf("Expected status 500, got %d", w.Code)
	}

	// Give a moment for async logging
	time.Sleep(50 * time.Millisecond)
}

func TestNewWithClient(t *testing.T) {
	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10,
		FlushInterval: 1 * time.Second,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	mw := NewWithClient(c)

	if mw == nil {
		t.Fatal("Expected middleware to be created")
	}
}

func TestMiddlewareRecordsMetadata(t *testing.T) {
	gin.SetMode(gin.TestMode)

	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10,
		FlushInterval: 1 * time.Second,
		Timeout:       100 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	router := gin.New()
	router.Use(New(Config{
		Client: c,
		CustomLabels: map[string]string{
			"app": "test",
			"env": "testing",
		},
		ServiceName: "test-service",
		Namespace:   "test-namespace",
	}))

	router.GET("/test", func(ctx *gin.Context) {
		ctx.JSON(200, gin.H{"message": "ok"})
	})

	// Send request with headers
	req := httptest.NewRequest("GET", "/test", nil)
	req.Header.Set("User-Agent", "test-agent/1.0")
	req.Header.Set("X-Forwarded-For", "192.168.1.1")

	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	// The middleware should have logged this request with all metadata
	// In a real integration test, we would verify the logged event
	time.Sleep(50 * time.Millisecond)
}

func BenchmarkMiddleware(b *testing.B) {
	gin.SetMode(gin.ReleaseMode)

	c, err := client.New("localhost:9999", &client.Options{
		BufferSize:    10000,
		FlushInterval: 10 * time.Second,
		Timeout:       100 * time.Millisecond,
	})
	if err != nil {
		b.Fatalf("Failed to create client: %v", err)
	}
	defer c.Close()

	router := gin.New()
	router.Use(NewWithClient(c))

	router.GET("/test", func(ctx *gin.Context) {
		ctx.Status(http.StatusOK)
	})

	req := httptest.NewRequest("GET", "/test", nil)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
	}
}
