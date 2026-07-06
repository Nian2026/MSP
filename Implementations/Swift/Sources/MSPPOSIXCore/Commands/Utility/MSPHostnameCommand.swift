import MSPCore

public struct MSPHostnameCommand: MSPCommand {
    public let name = "hostname"
    public let summary: String? = "Print the virtual host name."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        guard !invocation.arguments.contains("--help"),
              !invocation.arguments.contains("-h") else {
            return .success(stdout: mspHostnameUsage())
        }
        guard !invocation.arguments.contains("--version"),
              !invocation.arguments.contains("-V") else {
            return .success(stdout: "hostname 3.23\n")
        }

        var mode: MSPHostnameMode = .full
        var operands: [String] = []
        var parsingOptions = true
        for argument in invocation.arguments {
            if parsingOptions, argument == "--" {
                parsingOptions = false
                continue
            }
            if parsingOptions, argument.hasPrefix("--"), argument.count > 2 {
                switch argument {
                case "--short":
                    mode = .short
                case "--fqdn", "--long":
                    mode = .full
                case "--domain":
                    mode = .domain
                case "--alias", "--all-fqdns", "--ip-address", "--all-ip-addresses", "--yp", "--nis":
                    mode = .empty
                case "--boot", "--file":
                    return .failure(exitCode: 1, stderr: "hostname: changing host name is not supported\n")
                default:
                    if argument.hasPrefix("--file=") {
                        return .failure(exitCode: 1, stderr: "hostname: changing host name is not supported\n")
                    }
                    return MSPCommandResult(
                        stdout: mspHostnameUsage(),
                        stderr: "hostname: invalid option -- '\(String(argument.dropFirst(2).first ?? "?"))'\n",
                        exitCode: 255
                    )
                }
                continue
            }
            if parsingOptions, argument.hasPrefix("-"), argument != "-" {
                for option in argument.dropFirst() {
                    switch option {
                    case "s":
                        mode = .short
                    case "f":
                        mode = .full
                    case "d":
                        mode = .domain
                    case "a", "A", "i", "I", "y":
                        mode = .empty
                    case "b", "F":
                        return .failure(exitCode: 1, stderr: "hostname: changing host name is not supported\n")
                    default:
                        return MSPCommandResult(
                            stdout: mspHostnameUsage(),
                            stderr: "hostname: invalid option -- '\(option)'\n",
                            exitCode: 255
                        )
                    }
                }
                continue
            }
            operands.append(argument)
        }

        guard operands.isEmpty else {
            return .failure(exitCode: 1, stderr: "hostname: changing host name is not supported\n")
        }

        switch mode {
        case .full:
            return .success(stdout: MSPPOSIXVirtualIdentity.hostName + "\n")
        case .short:
            return .success(stdout: MSPPOSIXVirtualIdentity.shortHostName + "\n")
        case .domain:
            return .success(stdout: MSPPOSIXVirtualIdentity.domainName + "\n")
        case .empty:
            return .success(stdout: "\n")
        }
    }
}

private enum MSPHostnameMode {
    case full
    case short
    case domain
    case empty
}

private func mspHostnameUsage() -> String {
    """
    Usage: hostname [-b] {hostname|-F file}         set host name (from file)
           hostname [-a|-A|-d|-f|-i|-I|-s|-y]       display formatted name
           hostname                                 display host name

           {yp,nis,}domainname {nisdomain|-F file}  set NIS domain name (from file)
           {yp,nis,}domainname                      display NIS domain name

           dnsdomainname                            display dns domain name

           hostname -V|--version|-h|--help          print info and exit

    Program name:
           {yp,nis,}domainname=hostname -y
           dnsdomainname=hostname -d

    Program options:
        -a, --alias            alias names
        -A, --all-fqdns        all long host names (FQDNs)
        -b, --boot             set default hostname if none available
        -d, --domain           DNS domain name
        -f, --fqdn, --long     long host name (FQDN)
        -F, --file             read host name or NIS domain name from given file
        -i, --ip-address       addresses for the host name
        -I, --all-ip-addresses all addresses for the host
        -s, --short            short host name
        -y, --yp, --nis        NIS/YP domain name

    Description:
       This command can get or set the host name or the NIS domain name. You can
       also get the DNS domain or the FQDN (fully qualified domain name).
       Unless you are using bind or NIS for host lookups you can change the
       FQDN (Fully Qualified Domain Name) and the DNS domain name (which is
       part of the FQDN) in the /etc/hosts file.

    """
}
