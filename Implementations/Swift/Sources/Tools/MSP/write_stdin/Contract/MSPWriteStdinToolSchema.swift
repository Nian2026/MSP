public enum MSPWriteStdinToolSchema {
    public static let name = "write_stdin"
    public static let sessionIDArgumentName = "session_id"
    public static let charsArgumentName = "chars"
    public static let yieldTimeMillisecondsArgumentName = "yield_time_ms"
    public static let maxOutputTokensArgumentName = "max_output_tokens"
    public static let requiredArguments = ["session_id"]

    public static let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "session_id": {
          "type": "number",
          "description": "Session identifier returned by exec_command when the process is still running."
        },
        "chars": {
          "type": "string",
          "description": "Characters to write to stdin. Omit or pass an empty string to poll without writing."
        },
        "yield_time_ms": {
          "type": "number",
          "description": "Wait before yielding output. Non-empty writes default to 250 ms and cap at 30000 ms; empty polls wait 5000-300000 ms by default."
        },
        "max_output_tokens": {
          "type": "number",
          "description": "Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy."
        }
      },
      "required": [
        "session_id"
      ],
      "additionalProperties": false
    }
    """
}
