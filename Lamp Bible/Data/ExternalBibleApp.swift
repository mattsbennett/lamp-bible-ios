//
//  ExternalBibleApp.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-05.
//

import SwiftUI
import LampCore


struct ExternalBibleApp: Identifiable, Hashable {
    var id: String {
        self.name
    }
    
    var name: String
    var scheme: String
    var urlRoot: String
    
    func getFullUrl(sv: Int, ev: Int) -> URL? {
        LampExternalBibleApplication(rawValue: name)?.url(
            startReference: sv, endReference: ev
        ) { number in
            guard let book = try? BundledModuleDatabase.shared.getBook(id: number) else {
                return nil
            }
            return LampExternalBibleBook(
                number: number,
                name: book.name,
                osisID: book.osisParatextAbbreviation
            )
        }
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
