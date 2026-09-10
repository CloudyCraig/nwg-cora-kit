package com.natwest.payments.ledger;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

/**
 * Spring Data JPA repository. The Splunk OTel Java agent's JDBC instrumentation
 * automatically wraps every query and INSERT in a {@code db.system=postgresql}
 * span, which Splunk APM renders as an inferred-infrastructure node "postgres"
 * with one inbound edge from {@code ledger-service}.
 */
public interface LedgerEntryRepository extends JpaRepository<LedgerEntry, Long> {

    @Query("SELECT COALESCE(SUM(e.amountMinor), 0) FROM LedgerEntry e WHERE e.accountId = :accountId")
    long sumAmountByAccount(@Param("accountId") String accountId);

    /**
     * Drives the db-slow chaos scenario by issuing a real Postgres-side
     * sleep inside the @Transactional method, so the slowness shows up
     * everywhere a real slow query would:
     * <ul>
     *   <li>Splunk APM emits a JDBC client span whose duration equals the
     *       sleep, attributed to db.system=postgresql.</li>
     *   <li>{@code pg_stat_statements} records the SELECT, so Splunk APM
     *       Database Query Performance and the ITSI nwpay_l4_postgres
     *       service surface the new top-N slow query.</li>
     *   <li>The connection stays "active" for the sleep duration, so the
     *       postgres_exporter / native postgresqlreceiver "active backends"
     *       metric reflects real concurrency growth under load.</li>
     * </ul>
     * Historic implementations used a Java-side {@code Thread.sleep}
     * outside the JDBC spans; that lit up APM service health but left
     * every Postgres-side surface flat, which broke the "trace ->
     * Database Query Performance -> pg_stat_statements" demo arc. See
     * docs/customer/story-rum-apm-postgres.md for the full talk-track.
     *
     * @param seconds wall-clock delay (Postgres double precision). The
     *                caller is expected to clamp values from chaos
     *                triggers so a typo cannot wedge a connection for
     *                minutes; we do not clamp here because the column
     *                has no schema-side bound.
     * @return the {@code pg_sleep} result row (always null because
     *         pg_sleep returns void). Returned as {@link Object} so the
     *         repository compiles under both Hibernate 5 and 6 without
     *         the modifying-query workaround; callers discard it.
     */
    @Query(value = "SELECT pg_sleep(:seconds)", nativeQuery = true)
    Object chaosPgSleep(@Param("seconds") double seconds);
}
