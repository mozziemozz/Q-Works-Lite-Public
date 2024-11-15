import azure.functions as func
import logging
import phonenumbers
import json

# Change auth level to FUNCTION
app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

@app.route(route="FormatPhoneNumber")
def FormatPhoneNumber(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Processing request for phone number conversion.')

    try:
        # Log to check if phonenumbers is imported
        logging.info(f"phonenumbers version: {phonenumbers.__version__}")

        # Parse input from the request body
        req_body = req.get_json()
        phone_number = req_body.get('PhoneNumber')

        # Parse and convert the phone number
        parsed_number = phonenumbers.parse(phone_number)
        international_number = phonenumbers.format_number(parsed_number, phonenumbers.PhoneNumberFormat.INTERNATIONAL)

        # Replace hyphens with spaces in the formatted phone number
        international_number = international_number.replace('-', ' ')

        # Create JSON response including both original and international numbers
        response = {
            "OriginalPhoneNumber": phone_number,
            "InternationalPhoneNumber": international_number
        }

        return func.HttpResponse(
            json.dumps(response), 
            mimetype="application/json", 
            status_code=200
        )

    except Exception as e:
        logging.error(f"Error processing request: {e}")
        return func.HttpResponse(f"Invalid input or error processing phone number. {e}", status_code=400)