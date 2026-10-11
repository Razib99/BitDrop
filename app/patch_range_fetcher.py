import re

with open("rust/src/cloud/range_fetcher.rs", "r") as f:
    content = f.read()

replacement = """        let mut final_url = url.to_string();
        if let Some(token) = auth_token {
            // Append access_token to the query string.
            // When reqwest follows a 302 redirect from Google Drive to googleusercontent.com,
            // it strips the Authorization header for security reasons. Passing the token
            // in the URL ensures the redirect still authenticates.
            // Do NOT pass both the Authorization header and the query string,
            // as Google APIs will reject it with 400 or 403.
            if final_url.contains('?') {
                final_url = format!("{}&access_token={}", final_url, token);
            } else {
                final_url = format!("{}?access_token={}", final_url, token);
            }
        }

        let start_time = Instant::now();

        let req = self.client.get(&final_url).headers(headers);"""

content = re.sub(r'        let mut final_url = url\.to_string\(\);\n        if let Some\(token\) = auth_token \{.*?let req = self\.client\.get\(&final_url\)\.headers\(headers\);', replacement, content, flags=re.DOTALL)

with open("rust/src/cloud/range_fetcher.rs", "w") as f:
    f.write(content)
