import Foundation

struct SearchHit: Identifiable, Equatable {
    var id: UUID { item.id }
    var item: LauncherItem
    var collectionName: String
}
