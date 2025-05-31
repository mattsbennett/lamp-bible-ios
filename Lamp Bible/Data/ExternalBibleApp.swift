//
//  ExternalBibleApp.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-05.
//

import SwiftUI


struct ExternalBibleApp: Identifiable, Hashable {
    var id: String {
        self.name
    }
    
    var name: String
    var scheme: String
    var urlRoot: String
    
    func getFullUrl(sv: Int, ev: Int) -> URL? {
        let (startVerse, startChapter, startBook) = splitVerseId(sv)
        let (endVerse, endChapter, endBook) = splitVerseId(ev)
        let startBookObj = RealmManager.shared.realm.objects(Book.self).filter("id == \(startBook)").first!
        let endBookObj = RealmManager.shared.realm.objects(Book.self).filter("id == \(endBook)").first!
        let startBookOsis = startBookObj.osisParatextAbbreviation
        let startBookName = startBookObj.name.lowercased().trimmingCharacters(in: .whitespaces)
        let endBookName = endBookObj.name.lowercased().trimmingCharacters(in: .whitespaces)
        let endBookOsis = endBookObj.osisParatextAbbreviation
        var path = ""

        switch self.name {
            case "Accordance":
                // @todo Accordance uses zero-indexed verses (e.g. for Psalms where verse
                // 0 is the superscript) so we should use only chapters when possible
                // (i.e. when we just have a book/chapter range)
                path += "\(startBookOsis)_\(startChapter):\(startVerse)-\(endBookOsis)_\(endChapter):\(endVerse)"
            case "e-Sword LT":
                path += "\(startBookName).\(startChapter):\(startVerse)"
            case "Logos":
                path += "\(startBookName)\(startChapter):\(startVerse)"
            case "Olive Tree":
                path += "\(startBook).\(startChapter).\(startVerse)"
            case "YouVersion":
                if startBook == endBook && startChapter == endChapter {
                    path += "\(startBookOsis).\(startChapter).\(startVerse)-\(endVerse)"
                } else {
                    path += "\(startBookOsis).\(startChapter)"
                }
            default:
                path += ""
        }
        
        return URL(string: self.urlRoot + path)
    }
}

let externalBibleApps: [ExternalBibleApp] =
[
    ExternalBibleApp(
        name: "None",
        scheme: "",
        urlRoot: ""
    ),
    ExternalBibleApp(
        name: "Accordance",
        scheme: "accord://",
        urlRoot: "accord://read/"
    ),
    ExternalBibleApp(
        name: "e-Sword LT",
        scheme: "e-sword://",
        urlRoot: "e-sword://"
    ),
    ExternalBibleApp(
        name: "Logos",
        scheme: "logosres://",
        urlRoot: "https://ref.ly/"
    ),
    ExternalBibleApp(
        name: "Olive Tree",
        scheme: "olivetree://",
        urlRoot: "olivetree://bible/"
    ),
    ExternalBibleApp(
        name: "YouVersion",
        scheme: "youversion://",
        urlRoot: "youversion://bible?reference="
    ),
]
