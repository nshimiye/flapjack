@notifications @processor @notifier
Feature: notifications
  So people can be notified when things break and recover
  flapjack-notifier must send notifications correctly

  # TODO test across multiple contacts

  Scenario: Queue an SMS notification
    Given the user wants to receive SMS notifications for entity 'example.com'
    When an event notification is generated for entity 'example.com'
    Then an SMS notification for entity 'example.com' should be queued for the user
    And an email notification for entity 'example.com' should not be queued for the user

  Scenario: Queue a Nexmo SMS notification
    Given the user wants to receive Nexmo SMS notifications for entity 'example.com'
    When an event notification is generated for entity 'example.com'
    Then a Nexmo SMS notification for entity 'example.com' should be queued for the user
    And an email notification for entity 'example.com' should not be queued for the user
    And an SMS notification for entity 'example.com' should not be queued for the user

  Scenario: Queue an SNS notification
    Given the user wants to receive SNS notifications for entity 'example.com'
    When an event notification is generated for entity 'example.com'
    Then an SNS notification for entity 'example.com' should be queued for the user
    And an email notification for entity 'example.com' should not be queued for the user

  Scenario: Queue an email notification
    Given the user wants to receive email notifications for entity 'example.com'
    When an event notification is generated for entity 'example.com'
    Then an email notification for entity 'example.com' should be queued for the user
    And an SMS notification for entity 'example.com' should not be queued for the user

  Scenario: Queue SMS and email notifications
    Given the user wants to receive SMS notifications for entity 'example.com' and email notifications for entity 'example2.com'
    When an event notification is generated for entity 'example.com'
    And an event notification is generated for entity 'example2.com'
    Then an SMS notification for entity 'example.com' should be queued for the user
    And an SMS notification for entity 'example2.com' should not be queued for the user
    Then an email notification for entity 'example.com' should not be queued for the user
    And an email notification for entity 'example2.com' should be queued for the user

  Scenario: Send a queued SMS notification
    Given a user SMS notification has been queued for entity 'example.com'
    When the SMS notification handler runs successfully
    Then the user should receive an SMS notification

  Scenario: Send a queued Nexmo SMS notification
    Given a user Nexmo SMS notification has been queued for entity 'example.com'
    When the Nexmo SMS notification handler runs successfully
    Then the user should receive an Nexmo SMS notification

  Scenario: Send a queued SNS notification
    Given a user SNS notification has been queued for entity 'example.com'
    When the SNS notification handler runs successfully
    Then the user should receive an SNS notification

  Scenario: Handle a failure to send a queued SMS notification
    Given a user SMS notification has been queued for entity 'example.com'
    When the SMS notification handler fails to send an SMS
    Then the user should not receive an SMS notification

  Scenario: Handle a failure to send a queued SNS notification
    Given a user SNS notification has been queued for entity 'example.com'
    When the SNS notification handler fails to send an SMS
    Then the user should not receive an SNS notification

  Scenario: Send a queued email notification
    Given a user email notification has been queued for entity 'example.com'
    When the email notification handler runs successfully
    Then the user should receive an email notification

  Scenario: Handle a failure to send a queued email notification
    Given a user email notification has been queued for entity 'example.com'
    When the email notification handler fails to send an email
    Then the user should not receive an email notification
