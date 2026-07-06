enum MSPPythonLauncherSource {
    static let fileName = "msp-python-launcher.py"

    static let source = MSPPythonVirtualFileSystemBootstrapSource.source
        + "\n"
        + #"""
        import builtins
        import os
        import runpy as _msp_runpy
        import sys
        import traceback as _msp_traceback

        _MSP_WORKSPACE_ROOT = os.path.normpath(os.environ.get("MSP_PYTHON_WORKSPACE_ROOT", ""))

        def _msp_launcher_virtualize(value):
            try:
                if isinstance(value, str) and value and _MSP_WORKSPACE_ROOT:
                    absolute = os.path.normpath(os.path.abspath(value))
                    if absolute == _MSP_WORKSPACE_ROOT:
                        return "/"
                    prefix = _MSP_WORKSPACE_ROOT.rstrip(os.sep) + os.sep
                    if absolute.startswith(prefix):
                        return "/" + absolute[len(prefix):]
            except Exception:
                pass
            return value

        def _msp_launcher_set_path0(value):
            if sys.path:
                sys.path[0] = value
            else:
                sys.path.insert(0, value)

        def _msp_launcher_skip_option(arguments, index):
            argument = arguments[index]
            if argument in ("-W", "-X", "--check-hash-based-pycs"):
                return index + 2
            if argument.startswith("--check-hash-based-pycs="):
                return index + 1
            if argument.startswith("-W") or argument.startswith("-X"):
                return index + 1
            return index + 1

        def _msp_launcher_parse(arguments):
            index = 0
            requests_interactive = False
            while index < len(arguments):
                argument = arguments[index]
                if argument == "--":
                    if index + 1 < len(arguments):
                        return ("script", arguments[index + 1], arguments[index + 2:])
                    return ("interactive" if requests_interactive else "stdin", None, [])
                if argument == "-":
                    return ("stdin", None, arguments[index + 1:])
                if argument == "-c":
                    if index + 1 >= len(arguments):
                        raise SystemExit("python3: option -c requires an argument")
                    return ("command", arguments[index + 1], arguments[index + 2:])
                if argument.startswith("-c") and len(argument) > 2:
                    return ("command", argument[2:], arguments[index + 1:])
                if argument == "-m":
                    if index + 1 >= len(arguments):
                        raise SystemExit("python3: option -m requires an argument")
                    return ("module", arguments[index + 1], arguments[index + 2:])
                if argument.startswith("-m") and len(argument) > 2:
                    return ("module", argument[2:], arguments[index + 1:])
                if argument.startswith("-") and not argument.startswith("--"):
                    option_text = argument[1:]
                    offset = 0
                    while offset < len(option_text):
                        option = option_text[offset]
                        if option == "c":
                            command = option_text[offset + 1:]
                            if command:
                                return ("command", command, arguments[index + 1:])
                            if index + 1 >= len(arguments):
                                raise SystemExit("python3: option -c requires an argument")
                            return ("command", arguments[index + 1], arguments[index + 2:])
                        if option == "m":
                            module = option_text[offset + 1:]
                            if module:
                                return ("module", module, arguments[index + 1:])
                            if index + 1 >= len(arguments):
                                raise SystemExit("python3: option -m requires an argument")
                            return ("module", arguments[index + 1], arguments[index + 2:])
                        if option in ("W", "X"):
                            index = _msp_launcher_skip_option(arguments, index)
                            break
                        if option == "i":
                            requests_interactive = True
                        offset += 1
                    else:
                        index += 1
                    continue
                if argument.startswith("--"):
                    index = _msp_launcher_skip_option(arguments, index)
                    continue
                return ("script", argument, arguments[index + 1:])
            return ("interactive" if requests_interactive else "stdin", None, [])

        def _msp_launcher_exec(code, filename):
            globals_dict = {
                "__name__": "__main__",
                "__doc__": None,
                "__package__": None,
                "__loader__": None,
                "__spec__": None,
                "__builtins__": builtins,
            }
            if filename is not None:
                globals_dict["__file__"] = filename
            exec(compile(code, filename or "<stdin>", "exec"), globals_dict)

        def _msp_launcher_exit(code=None):
            raise SystemExit(code)

        def _msp_launcher_run_basic_repl():
            globals_dict = {
                "__name__": "__main__",
                "__doc__": None,
                "__package__": None,
                "__loader__": None,
                "__spec__": None,
                "__builtins__": builtins,
                "exit": _msp_launcher_exit,
                "quit": _msp_launcher_exit,
            }
            while True:
                line = sys.stdin.readline()
                if line == "":
                    return
                if not line.strip():
                    continue
                try:
                    exec(compile(line, "<stdin>", "single"), globals_dict)
                except SystemExit:
                    raise
                except Exception as _msp_repl_error:
                    _msp_launcher_print_user_exception(
                        type(_msp_repl_error),
                        _msp_repl_error,
                        _msp_repl_error.__traceback__
                    )

        def _msp_launcher_run():
            mode, payload, user_args = _msp_launcher_parse(sys.argv[1:])
            if mode == "command":
                sys.argv = ["-c"] + user_args
                _msp_launcher_set_path0("")
                _msp_launcher_exec(payload, "<string>")
                return
            if mode == "module":
                sys.argv = [payload] + user_args
                _msp_launcher_set_path0("")
                _msp_runpy.run_module(payload, run_name="__main__", alter_sys=False)
                return
            if mode == "script":
                virtual_script = _msp_launcher_virtualize(payload)
                sys.argv = [virtual_script] + user_args
                _msp_launcher_set_path0(os.path.dirname(payload) or "")
                with open(payload, "rb") as script_file:
                    source = script_file.read()
                _msp_launcher_exec(source, virtual_script)
                return
            if mode == "interactive":
                sys.argv = [""] + user_args
                _msp_launcher_set_path0("")
                _msp_launcher_run_basic_repl()
                return
            sys.argv = ["-"] + user_args
            _msp_launcher_set_path0("")
            source = sys.stdin.read()
            if source:
                _msp_launcher_exec(source, "<stdin>")

        def _msp_launcher_is_internal_frame(frame):
            filename = getattr(frame, "filename", "")
            name = getattr(frame, "name", "")
            return (
                os.path.basename(filename) == "msp-python-launcher.py"
                or name.startswith("_msp_launcher_")
                or name.startswith("_msp_vfs_")
            )

        def _msp_launcher_print_user_exception(exc_type, exc_value, exc_tb):
            extracted = [
                frame
                for frame in _msp_traceback.extract_tb(exc_tb)
                if not _msp_launcher_is_internal_frame(frame)
            ]
            sys.stderr.write("Traceback (most recent call last):\n")
            for frame in extracted:
                sys.stderr.write(f'  File "{frame.filename}", line {frame.lineno}, in {frame.name}\n')
            sys.stderr.write("".join(_msp_traceback.format_exception_only(exc_type, exc_value)))

        try:
            _msp_launcher_run()
        except SystemExit:
            raise
        except Exception as _msp_launcher_error:
            _msp_launcher_print_user_exception(
                type(_msp_launcher_error),
                _msp_launcher_error,
                _msp_launcher_error.__traceback__
            )
            sys.exit(1)
        """#
}
