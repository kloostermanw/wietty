import Foundation

/// A workspace's config file waiting to be agreed to, and what it wants to run.
///
/// Carries the workspace's name rather than only its id because it is a question
/// put to a user, and "this folder wants to run these commands" needs to name the
/// folder. The lines are exactly the ones not agreed to before, so a file that
/// mostly repeats what was approved asks only about what is new.
struct ConfigApprovalRequest: Identifiable, Equatable {
    var id: UUID { projectId }
    let projectId: UUID
    let workspaceName: String
    let commands: [String]
}
