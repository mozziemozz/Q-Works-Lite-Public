Invoke-RestMethod -Uri "Your Function URL" -Method Post -Body (@{PhoneNumber = "+41441234567" } | ConvertTo-Json) -ContentType "application/json"