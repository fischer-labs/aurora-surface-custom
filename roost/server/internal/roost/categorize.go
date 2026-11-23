package roost

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Category keys from shared/grocery/taxonomy.json.
var groceryCategories = []string{
	"produce", "bakery", "deli", "meat", "dairy", "frozen", "pantry", "international", "baking", "breakfast",
	"condiments", "snacks", "beverages", "alcohol", "baby", "health", "personal", "household", "pets", "other",
}

// categorizeWithLLM asks an OpenAI-compatible chat endpoint (Ollama, llama.cpp,
// vLLM, LM Studio…) to place unknown grocery items in aisles.
func categorizeWithLLM(ctx context.Context, cfg Config, items []string) (map[string]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	sys := "You sort grocery list items into supermarket aisles. Allowed aisle keys: " +
		strings.Join(groceryCategories, ", ") +
		". Reply with only a JSON object mapping each item exactly as given to one aisle key."
	payload := map[string]any{
		"model":       cfg.LLMModel,
		"temperature": 0,
		"messages": []map[string]string{
			{"role": "system", "content": sys},
			{"role": "user", "content": strings.Join(items, "\n")},
		},
		"response_format": map[string]string{"type": "json_object"},
	}
	buf, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.LLMURL+"/chat/completions", bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if cfg.LLMKey != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.LLMKey)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("llm status %d", res.StatusCode)
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Choices) == 0 {
		return nil, fmt.Errorf("llm response not understood")
	}
	return parseCategoryJSON(out.Choices[0].Message.Content, items), nil
}

// parseCategoryJSON accepts the first {...} block and keeps only valid keys.
func parseCategoryJSON(content string, items []string) map[string]string {
	result := map[string]string{}
	start, end := strings.Index(content, "{"), strings.LastIndex(content, "}")
	if start < 0 || end <= start {
		return result
	}
	var m map[string]string
	if json.Unmarshal([]byte(content[start:end+1]), &m) != nil {
		return result
	}
	valid := map[string]bool{}
	for _, c := range groceryCategories {
		valid[c] = true
	}
	lower := map[string]string{}
	for k, v := range m {
		lower[strings.ToLower(strings.TrimSpace(k))] = strings.ToLower(strings.TrimSpace(v))
	}
	for _, it := range items {
		if v := lower[strings.ToLower(strings.TrimSpace(it))]; valid[v] {
			result[it] = v
		}
	}
	return result
}
