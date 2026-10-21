import Foundation
import Testing
@testable import QualtiveCLICore

@Suite struct OutputTests {
    @Test func tableAlignsColumns() {
        let table = Output.table(headers: ["ID", "NAME"], rows: [["1", "Bugs"], ["200", "Ideas"]])
        #expect(table == "ID   NAME\n1    Bugs\n200  Ideas")
    }

    @Test func timestampIsUTC() {
        #expect(Output.timestamp(unixSeconds: 1_700_000_000) == "2023-11-14 22:13")
    }

    @Test func prettyJSONKeepsAllFields() throws {
        let json = try Output.prettyJSON(Data(#"[{"name":"Bugs","id":1,"extra":true}]"#.utf8))
        #expect(json.contains("\"extra\" : true"))
    }

    @Test func containersDecodeLeniently() throws {
        let data = Data(#"[{"id":"acme","name":"Acme","version":"qualtive"},{"id":7,"title":"Seven"},{"id":"x"}]"#.utf8)
        let containers = try JSONDecoder().decode([QualtiveCLICore.Container].self, from: data)
        #expect(containers == [
            QualtiveCLICore.Container(id: "acme", name: "Acme", version: "qualtive"),
            QualtiveCLICore.Container(id: "7", name: "Seven"),
            QualtiveCLICore.Container(id: "x"),
        ])
    }
}
