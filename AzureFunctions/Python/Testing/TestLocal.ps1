Invoke-RestMethod -Uri "http://localhost:7071/api/FormatPhoneNumber" -Method Post -Body (@{PhoneNumber = "+41441234567" } | ConvertTo-Json) -ContentType "application/json"