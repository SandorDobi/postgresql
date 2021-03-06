import Async

extension PostgreSQLConnection {
    /// Sends a parameterized PostgreSQL query command, collecting the parsed results.
    public func query(
        _ string: String,
        _ parameters: [PostgreSQLDataCustomConvertible] = []
    ) throws -> Future<[[String: PostgreSQLData]]> {
        var rows: [[String: PostgreSQLData]] = []
        return try query(string, parameters) { row in
            rows.append(row)
        }.map(to: [[String: PostgreSQLData]].self) {
            return rows
        }
    }

    /// Sends a parameterized PostgreSQL query command, returning the parsed results to
    /// the supplied closure.
    public func query(
        _ string: String,
        _ parameters: [PostgreSQLDataCustomConvertible] = [],
        resultFormat: PostgreSQLResultFormat = .binary(),
        onRow: @escaping ([String: PostgreSQLData]) -> ()
    ) throws -> Future<Void> {
        let parameters = try parameters.map { try $0.convertToPostgreSQLData() }
        logger?.log(query: string, parameters: parameters)
        let parse = PostgreSQLParseRequest(
            statementName: "",
            query: string,
            parameterTypes: parameters.map { $0.type }
        )
        let describe = PostgreSQLDescribeRequest(type: .statement, name: "")
        var currentRow: PostgreSQLRowDescription?
        
        return send([
            .parse(parse), .describe(describe), .sync
        ]) { message in
            switch message {
            case .parseComplete: break
            case .rowDescription(let row): currentRow = row
            case .parameterDescription: break
            case .noData: break
            default: throw PostgreSQLError(identifier: "query", reason: "Unexpected message during PostgreSQLParseRequest: \(message)", source: .capture())
            }
        }.flatMap(to: Void.self) {
            let resultFormats = resultFormat.formatCodeFactory(currentRow?.fields.map { $0.dataType } ?? [])
            // cache so we don't compute twice
            let bind = PostgreSQLBindRequest(
                portalName: "",
                statementName: "",
                parameterFormatCodes: parameters.map { $0.format },
                parameters: parameters.map { .init(data: $0.data) },
                resultFormatCodes: resultFormats
            )
            let execute = PostgreSQLExecuteRequest(
                portalName: "",
                maxRows: 0
            )
            return self.send([
                .bind(bind), .execute(execute), .sync
            ]) { message in
                switch message {
                case .bindComplete: break
                case .dataRow(let data):
                    guard let row = currentRow else {
                        throw PostgreSQLError(identifier: "query", reason: "Unexpected PostgreSQLDataRow without preceding PostgreSQLRowDescription.", source: .capture())
                    }
                    let parsed = try row.parse(data: data, formatCodes: resultFormats)
                    onRow(parsed)
                case .close: break
                case .noData: break
                default: throw PostgreSQLError(identifier: "query", reason: "Unexpected message during PostgreSQLParseRequest: \(message)", source: .capture())
                }
            }
        }
    }
}
