import Combine
import ConvexMobile
import Foundation

protocol TerminalServerDiscovering {
    var hostsPublisher: AnyPublisher<[TerminalHost], Never> { get }
}

final class TerminalServerDiscovery: TerminalServerDiscovering {
    let hostsPublisher: AnyPublisher<[TerminalHost], Never>

    @MainActor
    convenience init() {
        let memberships = ConvexClientManager.shared.client
            .subscribe(to: "teams:listTeamMemberships", yielding: TeamsListTeamMembershipsReturn.self)
            .catch { _ in
                Empty<TeamsListTeamMembershipsReturn, Never>()
            }
            .eraseToAnyPublisher()
        self.init(teamMemberships: memberships)
    }

    init(teamMemberships: AnyPublisher<TeamsListTeamMembershipsReturn, Never>) {
        self.hostsPublisher = teamMemberships
            .map { memberships -> [TerminalHost] in
                let hosts = memberships.flatMap { membership -> [TerminalHost] in
                    guard let metadata = membership.team.serverMetadata?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !metadata.isEmpty,
                        let catalog = try? TerminalServerCatalog(
                            metadataJSON: metadata,
                            teamID: membership.team.teamId
                        ) else {
                        return []
                    }

                    return catalog.hosts
                }

                return hosts
            }
            .eraseToAnyPublisher()
    }
}
