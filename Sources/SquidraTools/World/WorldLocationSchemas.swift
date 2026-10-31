import Foundation

/// Embedded for deployment; checked copies under Schemas/tools/world are verified by tests.
public enum WorldLocationSchemas {
    public static let inputSchema = Data(#"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:squidra:tool:world.get_entity_location@1.0.0:input",
  "type": "object",
  "properties": {
    "schemaVersion": {
      "type": "string",
      "maxLength": 1,
      "const": "1"
    },
    "entityId": {
      "type": "string",
      "maxLength": 36,
      "format": "uuid"
    },
    "validAt": {
      "type": "string",
      "maxLength": 35,
      "format": "date-time"
    },
    "knownAt": {
      "type": "string",
      "maxLength": 35,
      "format": "date-time"
    }
  },
  "required": [
    "schemaVersion",
    "entityId",
    "validAt",
    "knownAt"
  ],
  "additionalProperties": false
}
"""#.utf8)
    public static let outputSchema = Data(#"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:squidra:tool:world.get_entity_location@1.0.0:output",
  "type": "object",
  "properties": {
    "schemaVersion": {
      "type": "string",
      "maxLength": 1,
      "const": "1"
    },
    "actorId": {
      "type": "string",
      "maxLength": 36,
      "format": "uuid"
    },
    "entityId": {
      "type": "string",
      "maxLength": 36,
      "format": "uuid"
    },
    "validAt": {
      "type": "string",
      "maxLength": 35,
      "format": "date-time"
    },
    "knownAt": {
      "type": "string",
      "maxLength": 35,
      "format": "date-time"
    },
    "status": {
      "type": "string",
      "maxLength": 11,
      "enum": [
        "evidence",
        "no_evidence",
        "not_found"
      ]
    },
    "facts": {
      "type": "array",
      "maxItems": 32,
      "items": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "maxLength": 36,
            "format": "uuid"
          },
          "subjectId": {
            "type": "string",
            "maxLength": 36,
            "format": "uuid"
          },
          "locationId": {
            "type": "string",
            "maxLength": 36,
            "format": "uuid"
          },
          "frameId": {
            "type": "string",
            "maxLength": 36,
            "format": "uuid"
          },
          "sourceEventId": {
            "type": "string",
            "maxLength": 36,
            "format": "uuid"
          },
          "source": {
            "type": "string",
            "maxLength": 256,
            "minLength": 1
          },
          "confidence": {
            "type": "number",
            "minimum": 0,
            "maximum": 1
          },
          "basis": {
            "type": "string",
            "maxLength": 8,
            "enum": [
              "observed",
              "inferred"
            ]
          },
          "occurredAt": {
            "anyOf": [
              {
                "type": "string",
                "maxLength": 35,
                "format": "date-time"
              },
              {
                "type": "null"
              }
            ]
          },
          "observedAt": {
            "type": "string",
            "maxLength": 35,
            "format": "date-time"
          },
          "recordedAt": {
            "type": "string",
            "maxLength": 35,
            "format": "date-time"
          },
          "timeZone": {
            "type": "string",
            "maxLength": 128,
            "minLength": 1
          },
          "valid": {
            "type": "object",
            "properties": {
              "from": {
                "type": "string",
                "maxLength": 35,
                "format": "date-time"
              },
              "to": {
                "anyOf": [
                  {
                    "type": "string",
                    "maxLength": 35,
                    "format": "date-time"
                  },
                  {
                    "type": "null"
                  }
                ]
              }
            },
            "required": [
              "from",
              "to"
            ],
            "additionalProperties": false
          },
          "transaction": {
            "type": "object",
            "properties": {
              "from": {
                "type": "string",
                "maxLength": 35,
                "format": "date-time"
              },
              "to": {
                "anyOf": [
                  {
                    "type": "string",
                    "maxLength": 35,
                    "format": "date-time"
                  },
                  {
                    "type": "null"
                  }
                ]
              }
            },
            "required": [
              "from",
              "to"
            ],
            "additionalProperties": false
          }
        },
        "required": [
          "id",
          "subjectId",
          "locationId",
          "frameId",
          "sourceEventId",
          "source",
          "confidence",
          "basis",
          "occurredAt",
          "observedAt",
          "recordedAt",
          "timeZone",
          "valid",
          "transaction"
        ],
        "additionalProperties": false
      }
    },
    "uncertainty": {
      "type": "array",
      "maxItems": 4,
      "items": {
        "type": "string",
        "maxLength": 24,
        "enum": [
          "noEvidence",
          "inferredEvidence",
          "conflictingLocations",
          "projectionBehind"
        ]
      }
    },
    "projectedThroughSequence": {
      "anyOf": [
        {
          "type": "string",
          "maxLength": 19,
          "minLength": 1
        },
        {
          "type": "null"
        }
      ]
    },
    "availableThroughSequence": {
      "anyOf": [
        {
          "type": "string",
          "maxLength": 19,
          "minLength": 1
        },
        {
          "type": "null"
        }
      ]
    }
  },
  "required": [
    "schemaVersion",
    "actorId",
    "entityId",
    "validAt",
    "knownAt",
    "status",
    "facts",
    "uncertainty",
    "projectedThroughSequence",
    "availableThroughSequence"
  ],
  "additionalProperties": false
}
"""#.utf8)
}
