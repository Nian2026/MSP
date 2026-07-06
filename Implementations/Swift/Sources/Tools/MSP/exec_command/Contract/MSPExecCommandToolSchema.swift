public enum MSPExecCommandToolSchema {
    public static let name = "exec_command"
    public static let commandArgumentName = "cmd"
    public static let workdirArgumentName = "workdir"
    public static let shellArgumentName = "shell"
    public static let ttyArgumentName = "tty"
    public static let yieldTimeMillisecondsArgumentName = "yield_time_ms"
    public static let maxOutputTokensArgumentName = "max_output_tokens"
    public static let requiredArguments = ["cmd"]

    public static let parametersJSON = """
    {
      "type": "object",
      "properties": {
        "cmd": {
          "type": "string"
        },
        "workdir": {
          "type": "string",
          "description": "Working directory for the command. Defaults to the active workspace directory."
        },
        "shell": {
          "type": "string",
          "description": "Shell binary to launch. Defaults to the workspace shell."
        },
        "tty": {
          "type": "boolean",
          "description": "True allocates a PTY for terminal-like execution; false or omitted uses plain pipes."
        },
        "yield_time_ms": {
          "type": "number",
          "description": "Wait before yielding output. Defaults to 10000 ms; effective range is 250-30000 ms."
        },
        "max_output_tokens": {
          "type": "number",
          "description": "Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy."
        }
      },
      "required": [
        "cmd"
      ],
      "additionalProperties": false
    }
    """
}
