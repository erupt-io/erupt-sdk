/// A typed annotation attribute (generated in Types.swift from the erupt schema) or one of its values: what it
/// contributes to the build JSON.
public protocol AnnotationValue {
    var json: JSON { get }
}

extension AnnotationValue where Self: RawRepresentable, RawValue == String {
    public var json: JSON { .string(rawValue) }
}

extension JSON: AnnotationValue {
    public var json: JSON { self }
}

extension String: AnnotationValue {
    public var json: JSON { .string(self) }
}

extension Bool: AnnotationValue {
    public var json: JSON { .bool(self) }
}

extension Int: AnnotationValue {
    public var json: JSON { .int(Int64(self)) }
}

extension Double: AnnotationValue {
    public var json: JSON { .double(self) }
}

extension Array: AnnotationValue where Element: AnnotationValue {
    public var json: JSON { .array(map(\.json)) }
}

extension Dictionary: AnnotationValue where Key == String, Value: AnnotationValue {
    public var json: JSON { .object(mapValues(\.json)) }
}
