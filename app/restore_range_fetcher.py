import re

with open("rust/src/cloud/range_fetcher.rs", "r") as f:
    content = f.read()

replacement = """        let mut headers = HeaderMap::new();
        headers.insert(RANGE, HeaderValue::from_str(&range_val)?);

        if let Some(token) = auth_token {
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {}", token))?,
            );
        }

        let start_time = Instant::now();

        let req = self.client.get(url).headers(headers);"""

content = re.sub(r'        let mut headers = HeaderMap::new\(\);\n        headers\.insert\(RANGE, HeaderValue::from_str\(&range_val\)\?\);\n\n        let mut final_url = url\.to_string\(\);\n        if let Some\(token\) = auth_token \{.*?let req = self\.client\.get\(&final_url\)\.headers\(headers\);', replacement, content, flags=re.DOTALL)

with open("rust/src/cloud/range_fetcher.rs", "w") as f:
    f.write(content)
