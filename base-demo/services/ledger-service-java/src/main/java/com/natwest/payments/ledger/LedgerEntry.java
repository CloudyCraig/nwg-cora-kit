package com.natwest.payments.ledger;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;

/**
 * One row in the {@code ledger_entries} table. Created on every successful
 * call to {@code POST /process}.
 */
@Entity
@Table(name = "ledger_entries")
public class LedgerEntry {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "payment_id", nullable = false, length = 64)
    private String paymentId;

    @Column(name = "account_id", nullable = false, length = 32)
    private String accountId;

    @Column(name = "scheme", nullable = false, length = 16)
    private String scheme;

    @Column(name = "amount_minor", nullable = false)
    private long amountMinor;

    @Column(name = "currency", nullable = false, length = 8)
    private String currency;

    @Column(name = "direction", nullable = false, length = 1)
    private String direction;

    @Column(name = "created_at", nullable = false)
    private OffsetDateTime createdAt;

    public LedgerEntry() {}

    public LedgerEntry(String paymentId, String accountId, String scheme,
                       long amountMinor, String currency, String direction,
                       OffsetDateTime createdAt) {
        this.paymentId = paymentId;
        this.accountId = accountId;
        this.scheme = scheme;
        this.amountMinor = amountMinor;
        this.currency = currency;
        this.direction = direction;
        this.createdAt = createdAt;
    }

    public Long getId() { return id; }
    public String getPaymentId() { return paymentId; }
    public String getAccountId() { return accountId; }
    public String getScheme() { return scheme; }
    public long getAmountMinor() { return amountMinor; }
    public String getCurrency() { return currency; }
    public String getDirection() { return direction; }
    public OffsetDateTime getCreatedAt() { return createdAt; }
}
