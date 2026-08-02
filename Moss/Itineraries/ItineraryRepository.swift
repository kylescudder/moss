import Foundation
import PowerSync

@MainActor final class ItineraryRepository: ObservableObject {
    @Published private(set) var itemsByTrip:[UUID:[ItineraryItem]] = [:]
    @Published private(set) var isLoading=false
    @Published var lastError:String?
    private let database:PowerSyncDatabaseProtocol
    private var tasks:[UUID:Task<Void,Never>] = [:]
    private var userID:String?
    init(database:PowerSyncDatabaseProtocol){self.database=database}
    deinit { tasks.values.forEach{$0.cancel()} }
    func start(userID:String){self.userID=userID}
    func reset(){tasks.values.forEach{$0.cancel()};tasks.removeAll();itemsByTrip=[:];userID=nil;lastError=nil}
    func items(for trip:Trip)->[ItineraryItem]{itemsByTrip[trip.id,default:[]]}
    func refresh(tripID:UUID) async { guard tasks[tripID] == nil else{return}; isLoading=true; let database=database; let id=tripID.uuidString.lowercased(); tasks[tripID]=Task { [weak self] in do { for try await rows in try database.watch(sql:"select * from itinerary_items where trip_id=? and deleted_at is null order by starts_at asc,sort_order asc",parameters:[id],mapper:ItineraryItem.from(cursor:)){self?.itemsByTrip[tripID]=rows.compactMap{$0};self?.isLoading=false} } catch {self?.lastError=error.localizedDescription;self?.isLoading=false} } }
    func create(_ draft:ItineraryItemDraft,tripID:UUID) async -> ItineraryItem? { guard let userID,let ownerID=UUID(uuidString:userID) else{return nil};let uuid=UUID(),id=uuid.uuidString.lowercased(),now=Date().iso8601,sort=itemsByTrip[tripID,default:[]].count;do{try await database.execute(sql:"insert into itinerary_items (id,trip_id,owner_id,kind,title,location_name,starts_at,ends_at,notes,sort_order,created_at,updated_at) values (?,?,?,?,?,?,?,?,?,?,?,?)",parameters:[id,tripID.uuidString.lowercased(),userID,draft.kind.rawValue,draft.title.trimmingCharacters(in:.whitespacesAndNewlines),draft.locationName.nilIfBlank,draft.startsAt.iso8601,draft.endsAt.iso8601,draft.notes.nilIfBlank,sort,now,now]);return ItineraryItem(id:uuid,tripID:tripID,ownerID:ownerID,kind:draft.kind,title:draft.title,locationName:draft.locationName.nilIfBlank,startsAt:draft.startsAt,endsAt:draft.endsAt,notes:draft.notes.nilIfBlank,sortOrder:sort,createdAt:Date(),updatedAt:Date(),deletedAt:nil)}catch{lastError=error.localizedDescription;return nil} }
    func update(_ item:ItineraryItem) async {do{try await database.execute(sql:"update itinerary_items set kind=?,title=?,location_name=?,starts_at=?,ends_at=?,notes=?,sort_order=?,updated_at=? where id=?",parameters:[item.kind.rawValue,item.title,item.locationName,item.startsAt?.iso8601,item.endsAt?.iso8601,item.notes,item.sortOrder,Date().iso8601,item.id.uuidString.lowercased()])}catch{lastError=error.localizedDescription}}
    func softDelete(_ item:ItineraryItem) async {do{let now=Date().iso8601;try await database.execute(sql:"update itinerary_items set deleted_at=?,updated_at=? where id=?",parameters:[now,now,item.id.uuidString.lowercased()])}catch{lastError=error.localizedDescription}}
}
