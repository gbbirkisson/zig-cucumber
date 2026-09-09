Feature: The Gherkin parser

  Scenario: A feature with a doc string parses
    Given the feature file
      ```gherkin
      Feature: Greeting

        Scenario: A payload arrives
          Given the payload
            """json
            {
              "hello": "world"
            }
            """
      ```
    When I parse it
    Then it has 1 scenario
    And the feature is named "Greeting"
    And the scenario is named "A payload arrives"
    And the first step's doc string media type is "json"
    And the inner doc string round trips
