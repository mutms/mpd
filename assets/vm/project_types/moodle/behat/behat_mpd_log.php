<?php
// Behat context that mpd adds to every Moodle project's behat sites through
// $CFG->behat_config in config-mpd.php. Nothing of it lives in the Moodle
// tree.
//
// It keeps one log per behat site, MPD_BEHAT_LOG, that says which feature
// and scenario is running, when each starts and ends, and which step
// failed. PHP errors of the behat runner land in the same file, and so do
// the errors of the site's web requests (config-mpd.php points those
// there). Read together they tell which scenario an error belongs to,
// while a long run is still going.

use Behat\Behat\Context\Context;
use Behat\Behat\Hook\Scope\AfterFeatureScope;
use Behat\Behat\Hook\Scope\AfterScenarioScope;
use Behat\Behat\Hook\Scope\AfterStepScope;
use Behat\Behat\Hook\Scope\BeforeFeatureScope;
use Behat\Behat\Hook\Scope\BeforeScenarioScope;
use Behat\Testwork\Tester\Result\ExceptionResult;

class behat_mpd_log implements Context {
    /**
     * Send this process's PHP errors to the site's log and add a line.
     */
    protected static function write(string $line): void {
        if (!defined('MPD_BEHAT_LOG')) {
            return;
        }
        ini_set('log_errors', '1');
        ini_set('error_log', MPD_BEHAT_LOG);
        error_log($line);
    }

    /**
     * Path of a feature file from the project directory, with a line.
     */
    protected static function location(?string $file, int $line): string {
        $file = (string)$file;
        if (defined('MPD_PROJECT_NAME')) {
            $prefix = '/srv/projects/' . MPD_PROJECT_NAME . '/';
            if (str_starts_with($file, $prefix)) {
                $file = substr($file, strlen($prefix));
            }
        }
        return $file . ':' . $line;
    }

    /**
     * @BeforeFeature
     */
    public static function mpd_before_feature(BeforeFeatureScope $scope): void {
        $feature = $scope->getFeature();
        self::write('=== FEATURE START: ' . $feature->getTitle() . ' (' . self::location($feature->getFile(), 1) . ')');
    }

    /**
     * @AfterFeature
     */
    public static function mpd_after_feature(AfterFeatureScope $scope): void {
        $result = $scope->getTestResult()->isPassed() ? 'passed' : 'FAILED';
        self::write('=== FEATURE END ' . $result . ': ' . $scope->getFeature()->getTitle());
    }

    /**
     * @BeforeScenario
     */
    public function mpd_before_scenario(BeforeScenarioScope $scope): void {
        $scenario = $scope->getScenario();
        $where = self::location($scope->getFeature()->getFile(), $scenario->getLine());
        self::write('--- SCENARIO START: ' . $scenario->getTitle() . ' (' . $where . ')');
    }

    /**
     * @AfterStep
     */
    public function mpd_after_step(AfterStepScope $scope): void {
        $result = $scope->getTestResult();
        if ($result->isPassed()) {
            return;
        }
        $step = $scope->getStep();
        $where = self::location($scope->getFeature()->getFile(), $step->getLine());
        $line = '!!! STEP FAILED: ' . $step->getKeyword() . ' ' . $step->getText() . ' (' . $where . ')';
        if ($result instanceof ExceptionResult && $result->hasException()) {
            $message = preg_replace('/\s+/', ' ', $result->getException()->getMessage());
            $line .= ' — ' . mb_substr($message, 0, 500);
        }
        self::write($line);
    }

    /**
     * @AfterScenario
     */
    public function mpd_after_scenario(AfterScenarioScope $scope): void {
        $result = $scope->getTestResult()->isPassed() ? 'passed' : 'FAILED';
        self::write('--- SCENARIO END ' . $result . ': ' . $scope->getScenario()->getTitle());
    }
}
